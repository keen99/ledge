use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 5;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('background_revalidate', true)
        ledge:config_set('max_stale', 99999)
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, s-maxage=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 2: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
        local hdr = ngx.req.get_headers()
        ngx.say("Authorization: ",hdr["Authorization"])
        ngx.say("Cookie: ",hdr["Cookie"])
    ';
}
--- request
GET /stale_prx
--- more_headers
Authorization: foobar
Cookie: baz=qux
--- response_body
TEST 1
--- wait: 4
--- no_error_log
[error]


=== TEST 3: Cache has been revalidated
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.sleep(3)
        ledge:run()
    ';
}
location /stale_main {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    ';
}
--- request
GET /stale_prx
--- timeout: 6
--- response_body
TEST 2
Authorization: foobar
Cookie: baz=qux

=== TEST 4a: Re-prime and expire
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale_4 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4a")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_4_prx
--- response_body
TEST 4a


=== TEST 4b: Return stale when in offline mode
--- http_config eval: $::HttpConfig
--- config
location /stale_entry {
    echo_location /stale_4_prx;
    echo_flush;
    echo_sleep 3;
}
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.sleep(1)
        ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
        ledge:run()
    ';
}
location /stale_4 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4b")
    ';
}
--- request
GET /stale_entry
--- timeout: 5
--- response_body
TEST 4a
--- no_error_log
[error]


=== TEST 5a: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, s-maxage=0"
        end)
        ledge:run()
    ';
}
location /stale5 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60"
        ngx.say("TEST 5")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale5_prx
--- response_body
TEST 5


=== TEST 5b: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("revalidate_parent_headers", {"x-test", "x-test2"})
        ledge:bind("set_revalidation_headers", function(hdrs)
            hdrs["x-test2"] = "bazqux"
        end)
        ledge:run()
    ';
}
location /stale5 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5b")
        local hdr = ngx.req.get_headers()
        ngx.say("X-Test: ",hdr["X-Test"])
        ngx.say("X-Test2: ",hdr["X-Test2"])
        ngx.say("Cookie: ",hdr["Cookie"])
    ';
}
--- request
GET /stale5_prx
--- more_headers
X-Test: foobar
Cookie: baz=qux
--- response_body
TEST 5
--- wait: 4
--- no_error_log
[error]


=== TEST 5c: Cache has been revalidated, custom headers
--- http_config eval: $::HttpConfig
--- config
location /stale5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.sleep(3)
        ledge:run()
    ';
}
location /stale5_main {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5c")
    ';
}
--- request
GET /stale5_prx
--- timeout: 6
--- response_body
TEST 5b
X-Test: foobar
X-Test2: bazqux
Cookie: nil


=== TEST 8: Allow pending qless jobs to run
--- http_config eval: $::HttpConfig
--- config
location /qless {
    content_by_lua '
        ngx.sleep(10)
        ngx.say("QLESS")
    ';
}
--- request
GET /qless
--- timeout: 11
--- response_body
QLESS
--- no_error_log
[error]
