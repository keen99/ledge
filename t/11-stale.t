use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

our $StaleHttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('max_stale', 1000)
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
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 2: Honour max-stale request header
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
        ngx.say("TEST 2")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 3: Honour max_stale ledge config option
--- http_config eval: $::StaleHttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.say("TEST 3")
    ';
}
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 4: max_stale request overrides config
--- http_config eval: $::StaleHttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.say("TEST 4")
    ';
}
--- more_headers
Cache-Control: max-stale=0
--- request
GET /stale_prx
--- response_body
TEST 4


=== TEST 5a: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 5: Stale responses should set Warning header
--- http_config eval: $::StaleHttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.say("TEST 5")
    ';
}
--- request
GET /stale_prx
--- response_headers_like
Warning: 110 .*


=== TEST 5: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_s_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "s-maxage=0"
        end)
        ledge:run()
    ';
}
location /stale_s {
    content_by_lua '
        ngx.header["Cache-Control"] = "s-maxage=3600"
        ngx.say("TEST 5")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_s_prx
--- response_body
TEST 5


=== TEST 6: s-maxage prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_s_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.say("TEST 6")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_s_prx
--- response_body
TEST 6


=== TEST 7: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_pv_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, proxy-revalidate"
        end)
        ledge:run()
    ';
}
location /stale_pv {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, proxy-revalidate"
        ngx.say("TEST 7")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_pv_prx
--- response_body
TEST 7


=== TEST 8: proxy-revalidate prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_pv_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_pv {
    content_by_lua '
        ngx.say("TEST 8")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_pv_prx
--- response_body
TEST 8


=== TEST 9: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_mv_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, must-revalidate"
        end)
        ledge:run()
    ';
}
location /stale_mv {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, must-revalidate"
        ngx.say("TEST 9")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_mv_prx
--- response_body
TEST 9


=== TEST 10: must-revalidate prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_mv_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_mv {
    content_by_lua '
        ngx.say("TEST 10")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_mv_prx
--- response_body
TEST 10


=== TEST 11: Do not attempt to serve stale with no cache entry
--- http_config eval: $::HttpConfig
--- config
location /stale_subzero_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_subzero {
    content_by_lua '
        ngx.say("TEST 11")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_subzero_prx
--- response_body
TEST 11
