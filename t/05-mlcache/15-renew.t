# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use lib '.';
use t::Util;

no_long_string();

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm      1m;
    lua_shared_dict  cache_shm_miss 1m;
    lua_shared_dict  ipc_shm        1m;

    init_by_lua_block {
        -- local verbose = true
        local verbose = false
        local outfile = "$Test::Nginx::Util::ErrLogFile"
        -- local outfile = "/tmp/v.log"
        if verbose then
            local dump = require "jit.dump"
            dump.on(nil, outfile)
        else
            local v = require "jit.v"
            v.on(outfile)
        end

        require "resty.core"
        -- jit.opt.start("hotloop=1")
        -- jit.opt.start("loopunroll=1000000")
        -- jit.off()
    }
};

run_tests();

__DATA__

=== TEST 1: renew() errors if no ipc
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local ok, err = pcall(cache.renew, cache)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no ipc to propagate renew, specify opts.ipc_shm or opts.ipc
--- no_error_log
[error]



=== TEST 2: renew() validates key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.renew, cache)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
key must be a string
--- no_error_log
[error]



=== TEST 3: renew() accepts callback as function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.renew, cache, "key", nil, function() end)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]



=== TEST 4: renew() rejects callbacks not nil or function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.renew, cache, "key", nil, "not a function")
            if not ok then
                ngx.say(err)
            end

            local ok, err = pcall(cache.renew, cache, "key", nil, false)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
callback must be a function
callback must be a function
--- no_error_log
[error]



=== TEST 5: renew() validates opts
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.renew, cache, "key", "opts")
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts must be a table
--- no_error_log
[error]



=== TEST 6: renew() calls callback in protected mode with stack traceback
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                error("oops")
            end

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body_like chomp
callback threw an error: .*? oops
stack traceback:
\s+\[C\]: in function 'error'
\s+content_by_lua\(nginx\.conf:\d+\):\d+: in function
--- no_error_log
[error]



=== TEST 7: renew() is resilient to callback runtime errors with non-string arguments
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:renew("key", nil, function() error(ngx.null) end)
            if err then
                ngx.say(err)
            end

            local data, err = cache:renew("key", nil, function() error({}) end)
            if err then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body_like
callback threw an error: userdata: NULL
callback threw an error: table: 0x[0-9a-fA-F]+
--- no_error_log
[error]



=== TEST 8: renew() caches a number
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return 123
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: number 123
from lru: number 123
from shm: number 123
--- no_error_log
[error]



=== TEST 9: renew() caches a boolean (true)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return true
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: boolean true
from lru: boolean true
from shm: boolean true
--- no_error_log
[error]



=== TEST 10: renew() caches a boolean (false)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return false
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: boolean false
from lru: boolean false
from shm: boolean false
--- no_error_log
[error]



=== TEST 11: renew() caches nil
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return nil
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: nil nil
from lru: nil nil
from shm: nil nil
--- no_error_log
[error]



=== TEST 12: renew() caches nil in 'shm_miss' if specified
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            local dict_miss = ngx.shared.cache_shm_miss
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                shm_miss = "cache_shm_miss",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            -- from callback

            local data, err = cache:renew("key", nil, function() return nil end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("from callback: ", type(data), " ", data)

            -- direct shm checks
            -- concat key since shm values are namespaced per their the
            -- mlcache name
            local key = "my_mlcachekey"

            local v, err = dict:get(key)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("no value in shm: ", v == nil)

            local v, err = dict_miss:get(key)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("value in shm_miss is a sentinel nil value: ", v ~= nil)

            -- subsequent calls from shm

            cache.lru:delete("key")

            -- here, we return 'true' and not nil in the callback. this is to
            -- ensure that get() will check the shm_miss shared dict and read
            -- the nil sentinel value in there, thus will not call the
            -- callback.

            local data, err = cache:get("key", nil, function() return true end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("from shm: ", type(data), " ", data)

            -- from lru

            local v = cache.lru:get("key")

            ngx.say("value in lru is a sentinel nil value: ", v ~= nil)
        }
    }
--- request
GET /t
--- response_body
from callback: nil nil
no value in shm: true
value in shm_miss is a sentinel nil value: true
from shm: nil nil
value in lru is a sentinel nil value: true
--- no_error_log
[error]



=== TEST 13: renew() caches a string
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return "hello world"
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: string hello world
from lru: string hello world
from shm: string hello world
--- no_error_log
[error]



=== TEST 14: renew() caches a table
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require "cjson"
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return {
                    hello = "world",
                    subt  = { foo = "bar" }
                }
            end

            -- from callback

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data.hello, " ", data.subt.foo)

            -- from lru

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data.hello, " ", data.subt.foo)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data.hello, " ", data.subt.foo)
        }
    }
--- request
GET /t
--- response_body
from callback: table world bar
from lru: table world bar
from shm: table world bar
--- no_error_log
[error]



=== TEST 15: renew() errors when caching an unsupported type
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require "cjson"
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return ngx.null
            end

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
        }
    }
--- request
GET /t
--- error_code: 500
--- error_log eval
qr/\[error\] .*?init\.lua:\d+: cannot cache value of type userdata/



=== TEST 16: renew() calls callback with args
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb(a, b)
                return a + b
            end

            local data, err = cache:renew("key", nil, cb, 1, 2)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
3
--- no_error_log
[error]



=== TEST 17: renew() caches hit for 'ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3,
            }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:renew("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 18: renew() caches miss (nil) for 'neg_ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl     = 10,
                neg_ttl = 0.3
            }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:renew("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 19: renew() caches for 'opts.ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 10,
            }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:renew("key", { ttl = 0.3 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 20: renew() caches for 'opts.neg_ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                neg_ttl = 2,
            }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:renew("key", { neg_ttl = 0.3 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 21: renew() with ttl of 0 means indefinite caching
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3,
            }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:renew("key", { ttl = 0 }, cb))
            assert(data == 123)

            ngx.sleep(0.4)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("in LRU after 1.1s: stale")

            else
                ngx.say("in LRU after exp: ", data)
            end

            cache.lru:delete("key")

            -- still in shm
            data = assert(cache:get("key"))

            ngx.say("in shm after exp: ", data)
        }
    }
--- request
GET /t
--- response_body
in callback
in LRU after exp: 123
in shm after exp: 123
--- no_error_log
[error]



=== TEST 22: renew() with neg_ttl of 0 means indefinite caching for nil values
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3,
            }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:renew("key", { neg_ttl = 0 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.4)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("in LRU after 0.4s: stale")

            else
                ngx.say("in LRU after exp: ", tostring(data))
            end

            cache.lru:delete("key")

            -- still in shm
            data, err = cache:get("key")
            assert(err == nil, err)

            ngx.say("in shm after exp: ", tostring(data))
        }
    }
--- request
GET /t
--- response_body_like
in callback
in LRU after exp: table: \S+
in shm after exp: nil
--- no_error_log
[error]



=== TEST 23: renew() errors when ttl < 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local ok, err = pcall(cache.renew, cache, "key", { ttl = -1 }, cb)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.ttl must be >= 0
--- no_error_log
[error]



=== TEST 24: renew() errors when neg_ttl < 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local ok, err = pcall(cache.renew, cache, "key", { neg_ttl = -1 }, cb)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.neg_ttl must be >= 0
--- no_error_log
[error]



=== TEST 25: renew() shm -> LRU caches for 'opts.ttl - since' in ms
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return 123
            end

            local data = assert(cache:renew("key", { ttl = 0.5 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with smaller ttl
            data, err = assert(cache:get("key"))
            assert(data == 123)

            ngx.sleep(0.2)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end

            ngx.sleep(0.1)

            -- expired in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end
        }
    }
--- request
GET /t
--- response_body
is not expired in LRU: 123
is stale in LRU: 123
--- no_error_log
[error]



=== TEST 26: renew() shm -> LRU caches non-nil for 'indefinite' if ttl is 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return 123
            end

            local data = assert(cache:renew("key", { ttl = 0 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with indefinite ttl too
            data, err = assert(cache:get("key"))
            assert(data == 123)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end
        }
    }
--- request
GET /t
--- response_body
is not expired in LRU: 123
--- no_error_log
[error]



=== TEST 27: renew() shm -> LRU caches for 'opts.neg_ttl - since' in ms
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil
            end

            local data, err = cache:renew("key", { neg_ttl = 0.5 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with smaller ttl
            data, err = cache:get("key")
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", tostring(stale))

            else
                ngx.say("is not expired in LRU: ", tostring(data))
            end

            ngx.sleep(0.1)

            -- expired in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", tostring(stale))

            else
                ngx.say("is not expired in LRU: ", tostring(data))
            end
        }
    }
--- request
GET /t
--- response_body_like
is not expired in LRU: table: \S+
is stale in LRU: table: \S+
--- no_error_log
[error]



=== TEST 28: renew() shm -> LRU caches nil for 'indefinite' if neg_ttl is 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil
            end

            local data, err = cache:renew("key", { neg_ttl = 0 }, cb)
            assert(err == nil)
            assert(data == nil)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with indefinite ttl too
            data, err = cache:get("key")
            assert(err == nil)
            assert(data == nil)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            ngx.say("is stale in LRU: ", stale)

            -- data is a table (nil sentinel value) so rely on stale instead
        }
    }
--- request
GET /t
--- response_body
is stale in LRU: nil
--- no_error_log
[error]



=== TEST 29: renew() returns ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return 123
            end

            local _, _, ttl = assert(cache:renew("key", nil, cb))
            ngx.say("ttl from callback: ", ttl)

            _, _, hit_lvl = assert(cache:get("key"))
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = assert(cache:get("key"))
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl from callback: 30
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 30: renew() returns infinite ttl as zero
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return 123
            end

            local _, _, ttl = assert(cache:renew("key", { ttl = 0 }, cb))
            ngx.say("ttl from callback: ", ttl)

            _, _, hit_lvl = assert(cache:get("key"))
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = assert(cache:get("key"))
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl from callback: 0
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 31: renew() returns ttl for nil hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil
            end

            local _, _, ttl = cache:renew("key", nil, cb)
            ngx.say("ttl from callback: ", ttl)

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl from callback: 5
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 32: renew() returns infinite ttl as zero for nil hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil
            end

            local _, _, ttl = cache:renew("key", { neg_ttl = 0 }, cb)
            ngx.say("ttl from callback: ", ttl)

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl from callback: 0
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 33: renew() returns ttl for boolean false hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return false
            end

            local _, _, ttl = cache:renew("key", nil, cb)
            ngx.say("ttl from callback: ", ttl)

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = cache:get("key")
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl from callback: 30
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 34: renew() callback can return nil + err (string)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil, "an error occurred"
            end

            local data, err = cache:renew("1", nil, cb)
            if err then
                ngx.say("cb return values: ", data, " ", err)
            end

            local function cb2()
                -- we will return "foo" to users as well from get(), and
                -- not just nil, if they wish so.
                return "foo", "an error occurred again"
            end

            data, err = cache:renew("2", nil, cb2)
            if err then
                ngx.say("cb2 return values: ", data, " ", err)
            end
        }
    }
--- request
GET /t
--- response_body
cb return values: nil an error occurred
cb2 return values: foo an error occurred again
--- no_error_log
[error]



=== TEST 35: renew() callback can return nil + err (non-string) safely
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local function cb()
                return nil, { err = "an error occurred" } -- invalid usage
            end

            local data, err = cache:renew("1", nil, cb)
            if err then
                ngx.say("cb return values: ", data, " ", err)
            end

            local function cb2()
                -- we will return "foo" to users as well from get(), and
                -- not just nil, if they wish so.
                return "foo", { err = "an error occurred again" } -- invalid usage
            end

            data, err = cache:renew("2", nil, cb2)
            if err then
                ngx.say("cb2 return values: ", data, " ", err)
            end
        }
    }
--- request
GET /t
--- response_body_like chomp
cb return values: nil table: 0x[[:xdigit:]]+
cb2 return values: foo table: 0x[[:xdigit:]]+
--- no_error_log
[error]



=== TEST 36: renew() callback can return nil + err (table) and will call __tostring
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local mt = {
                __tostring = function()
                    return "hello from __tostring"
                end
            }

            local function cb()
                return nil, setmetatable({}, mt)
            end

            local data, err = cache:renew("1", nil, cb)
            if err then
                ngx.say("cb return values: ", data, " ", err)
            end
        }
    }
--- request
GET /t
--- response_body
cb return values: nil hello from __tostring
--- no_error_log
[error]



=== TEST 37: renew() callback's 3th return value can override the ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local opts  = {
                ipc_shm = "ipc_shm",
                ttl = 10,
            }
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", opts))

            local function cb()
                ngx.say("in callback 1")
                return 1, nil, 0.1
            end

            local function cb2()
                ngx.say("in callback 2")
                return 2
            end

            -- cache our value (runs cb)

            local data, err = cache:renew("key", opts, cb)
            assert(err == nil, err)
            assert(data == 1)

            -- should not run cb2

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 1)

            ngx.sleep(0.15)

            -- should run cb2 (value expired)

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 2)
        }
    }
--- request
GET /t
--- response_body
in callback 1
in callback 2
--- no_error_log
[error]



=== TEST 38: renew() callback's 3th return value can override the neg_ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local opts  = {
                ipc_shm = "ipc_shm",
                ttl = 10,
                neg_ttl = 10,
            }
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", opts))

            local function cb()
                ngx.say("in callback 1")
                return nil, nil, 0.1
            end

            local function cb2()
                ngx.say("in callback 2")
                return 1
            end

            -- cache our value (runs cb)

            local data, err = cache:renew("key", opts, cb)
            assert(err == nil, err)
            assert(data == nil)

            -- should not run cb2

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.15)

            -- should run cb2 (value expired)

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 1)
        }
    }
--- request
GET /t
--- response_body
in callback 1
in callback 2
--- no_error_log
[error]



=== TEST 39: renew() ignores invalid callback 3rd return value (not number)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local opts  = {
                ipc_shm = "ipc_shm",
                ttl = 0.1,
                neg_ttl = 0.1,
            }
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", opts))

            local function pos_cb()
                ngx.say("in positive callback")
                return 1, nil, "success"
            end

            local function neg_cb()
                ngx.say("in negative callback")
                return nil, nil, {}
            end

            ngx.say("Test A: string TTL return value for positive data is ignored")

            -- cache our value (runs pos_cb)

            local data, err = cache:renew("pos_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)

            -- neg_cb should not run

            data, err = cache:get("pos_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == 1)

            ngx.sleep(0.15)

            -- should run neg_cb

            data, err = cache:get("pos_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.say("Test B: table TTL return value for negative data is ignored")

            -- cache our value (runs neg_cb)

            data, err = cache:renew("neg_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)

            -- pos_cb should not run

            data, err = cache:get("neg_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.15)

            -- should run pos_cb

            data, err = cache:get("neg_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)
        }
    }
--- request
GET /t
--- response_body
Test A: string TTL return value for positive data is ignored
in positive callback
in negative callback
Test B: table TTL return value for negative data is ignored
in negative callback
in positive callback
--- no_error_log
[error]



=== TEST 40: renew() passes 'resty_lock_opts' for L3 calls
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local resty_lock = require "resty.lock"
            local mlcache = require "kong.resty.mlcache"

            local resty_lock_opts = { timeout = 5 }

            do
                local orig_resty_lock_new = resty_lock.new
                resty_lock.new = function(_, dict_name, opts, ...)
                    ngx.say("was given 'opts.resty_lock_opts': ", opts == resty_lock_opts)

                    return orig_resty_lock_new(_, dict_name, opts, ...)
                end
            end

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                resty_lock_opts = resty_lock_opts,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:renew("key", nil, function() return nil end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
        }
    }
--- request
GET /t
--- response_body
was given 'opts.resty_lock_opts': true
--- no_error_log
[error]



=== TEST 41: renew() errors on lock timeout
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            ngx.shared.cache_shm:set(1, true, 0.2)
            ngx.shared.cache_shm:set(2, true, 0.2)
        }

        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"
            local cache_1 = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3
            }))
            local cache_2 = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3,
                resty_lock_opts = {
                    timeout = 0.2
                }
            }))

            local function cb(delay, return_val)
                if delay then
                    ngx.sleep(delay)
                end

                return return_val or 123
            end

            -- cache in shm

            local data, err, ttl = cache_1:renew("my_key", nil, cb)
            assert(data == 123)
            assert(err == nil)
            assert(ttl == 0.3)

            -- make shm + LRU expire

            ngx.sleep(0.3)

            local t1 = ngx.thread.spawn(function()
                -- trigger L3 callback again, but slow to return this time
                cache_1:get("my_key", nil, cb, 0.3, 456)
            end)

            local t2 = ngx.thread.spawn(function()
                -- make this mlcache wait on other's callback, and timeout
                local data, err, ttl = cache_2:renew("my_key", nil, cb)
                ngx.say("data: ", data)
                ngx.say("err: ", err)
                ngx.say("ttl: ", ttl)
            end)

            assert(ngx.thread.wait(t1))
            assert(ngx.thread.wait(t2))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache_2:get("my_key", nil, cb, nil, 123)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl) -- should be 1 since LRU instances are shared by mlcache namespace, and t1 finished
        }
    }
--- request
GET /t
--- response_body
data: nil
err: could not acquire callback lock: timeout
ttl: nil

-> subsequent get()
data: 456
err: nil
hit_lvl: 1
--- no_error_log
[error]



=== TEST 42: renew() returns data even if failed to set in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            local mlcache = require "kong.resty.mlcache"

            -- fill up shm

            local idx = 0

            while true do
                local ok, err, forcible = dict:set(idx, string.rep("a", 2^5))
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                if forcible then
                    break
                end

                idx = idx + 1
            end

            -- now, trigger a hit with a value many times as large

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local data, err = cache:renew("key", nil, function()
                return string.rep("a", 2^20)
            end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("data type: ", type(data))
        }
    }
--- request
GET /t
--- response_body
data type: string
--- error_log eval
qr/\[warn\] .*? could not write to lua_shared_dict 'cache_shm' after 3 tries \(no memory\), it is either/
--- no_error_log
[error]



=== TEST 43: renew() errors on invalid opts.shm_set_tries
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local values = {
                "foo",
                -1,
                0,
            }

            for _, v in ipairs(values) do
                local ok, err = pcall(cache.renew, cache, "key", {
                    shm_set_tries = v
                }, function() end)
                if not ok then
                    ngx.say(err)
                end
            end
        }
    }
--- request
GET /t
--- response_body
opts.shm_set_tries must be a number
opts.shm_set_tries must be >= 1
opts.shm_set_tries must be >= 1
--- no_error_log
[error]



=== TEST 44: renew() with default shm_set_tries to LRU evict items when a large value is being cached
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            dict:flush_all()
            dict:flush_expired()
            local mlcache = require "kong.resty.mlcache"

            -- fill up shm

            local idx = 0

            while true do
                local ok, err, forcible = dict:set(idx, string.rep("a", 2^2))
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                if forcible then
                    break
                end

                idx = idx + 1
            end

            -- shm:set() will evict up to 30 items when the shm is full
            -- now, trigger a hit with a larger value which should trigger LRU
            -- eviction and force the slab allocator to free pages

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local cb_calls = 0
            local function cb()
                cb_calls = cb_calls + 1
                return string.rep("a", 2^5)
            end

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("type of data in shm: ", type(data))
            ngx.say("callback was called: ", cb_calls, " times")
        }
    }
--- request
GET /t
--- response_body
type of data in shm: string
callback was called: 1 times
--- no_error_log
[warn]
[error]



=== TEST 45: renew() respects instance opts.shm_set_tries to LRU evict items when a large value is being cached
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            dict:flush_all()
            dict:flush_expired()
            local mlcache = require "kong.resty.mlcache"

            -- fill up shm

            local idx = 0

            while true do
                local ok, err, forcible = dict:set(idx, string.rep("a", 2^2))
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                if forcible then
                    break
                end

                idx = idx + 1
            end

            -- shm:set() will evict up to 30 items when the shm is full
            -- now, trigger a hit with a larger value which should trigger LRU
            -- eviction and force the slab allocator to free pages

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                shm_set_tries = 5,
            }))

            local cb_calls = 0
            local function cb()
                cb_calls = cb_calls + 1
                return string.rep("a", 2^12)
            end

            local data, err = cache:renew("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("type of data in shm: ", type(data))
            ngx.say("callback was called: ", cb_calls, " times")
        }
    }
--- request
GET /t
--- response_body
type of data in shm: string
callback was called: 1 times
--- no_error_log
[warn]
[error]



=== TEST 46: renew() accepts opts.shm_set_tries to LRU evict items when a large value is being cached
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            dict:flush_all()
            dict:flush_expired()
            local mlcache = require "kong.resty.mlcache"

            -- fill up shm

            local idx = 0

            while true do
                local ok, err, forcible = dict:set(idx, string.rep("a", 2^2))
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                if forcible then
                    break
                end

                idx = idx + 1
            end

            -- now, trigger a hit with a value ~3 times as large
            -- which should trigger retries and eventually remove 9 other
            -- cached items

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local cb_calls = 0
            local function cb()
                cb_calls = cb_calls + 1
                return string.rep("a", 2^12)
            end

            local data, err = cache:renew("key", {
                shm_set_tries = 5
            }, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("type of data in shm: ", type(data))
            ngx.say("callback was called: ", cb_calls, " times")
        }
    }
--- request
GET /t
--- response_body
type of data in shm: string
callback was called: 1 times
--- no_error_log
[warn]
[error]



=== TEST 47: renew() caches data in L1 LRU even if failed to set in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            dict:flush_all()
            dict:flush_expired()
            local mlcache = require "kong.resty.mlcache"

            -- fill up shm

            local idx = 0

            while true do
                local ok, err, forcible = dict:set(idx, string.rep("a", 2^2))
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                if forcible then
                    break
                end

                idx = idx + 1
            end

            -- now, trigger a hit with a value many times as large

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.3,
                shm_set_tries = 1,
            }))

            local data, err = cache:renew("key", nil, function()
                return string.rep("a", 2^20)
            end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local data = cache.lru:get("key")
            ngx.say("type of data in LRU: ", type(data))

            ngx.say("sleeping...")
            ngx.sleep(0.4)

            local _, stale = cache.lru:get("key")
            ngx.say("is stale: ", stale ~= nil)
        }
    }
--- request
GET /t
--- response_body
type of data in LRU: string
sleeping...
is stale: true
--- no_error_log
[error]



=== TEST 48: renew() does not cache value in LRU indefinitely when retrieved from shm on last ms (see GH PR #58)
--- SKIP
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                ttl = 0.2,
            }))

            local lru = cache.lru

            local function cb(v)
                return v or 42
            end

            local data, err, ttl = cache:renew("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("ttl: ", ttl)

            local data, err, hit_lvl = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)

            lru:delete("key")

            data, err, hit_lvl = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)

            data, err, hit_lvl = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.sleep(0.2)

            data, err, hit_lvl = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.update_time()
            local start = ngx.now() * 1000
            while true do
                lru:delete("key")
                data, err, hit_lvl = cache:get("key", nil, cb)
                if hit_lvl == 3 then
                    assert(data == 42, err or "invalid data value: " .. data)
                    ngx.say("hit_lvl: ", hit_lvl)
                    break
                end
                ngx.sleep(0)
            end
            ngx.update_time()
            local took = ngx.now() * 1000 - start
            assert(took > 198 and took < 202)

            data, err, hit_lvl = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.sleep(0.201)

            data, err, hit_lvl = cache:get("key", nil, cb, 91)
            assert(data == 91, err or "invalid data value: " .. data)
            ngx.say("hit_lvl: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
ttl: 0.2
hit_lvl: 1
hit_lvl: 2
hit_lvl: 1
hit_lvl: 3
hit_lvl: 3
hit_lvl: 1
hit_lvl: 3
--- no_error_log
[error]



=== TEST 49: renew() bypass cache for negative callback TTL
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local opts  = {
                ipc_shm = "ipc_shm",
                ttl = 0.1,
                neg_ttl = 0.1,
            }
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", opts))

            local function pos_cb()
                ngx.say("in positive callback")
                return 1, nil, -1
            end

            local function neg_cb()
                ngx.say("in negative callback")
                return nil, nil, -1
            end

            ngx.say("Test A: negative TTL return value for positive data bypasses cache")

            -- don't cache our value (runs pos_cb)

            local data, err, ttl = cache:renew("pos_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)
            assert(ttl == -1)

            -- pos_cb should run again

            local data, err, hit_level = cache:get("pos_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)
            assert(hit_level == 3)

            ngx.say("Test B: negative TTL return value for negative data bypasses cache")

            -- don't cache our value (runs neg_cb)

            data, err, ttl = cache:renew("neg_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)
            assert(ttl == -1)

            -- neg_cb should run again

            data, err, hit_level = cache:get("neg_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)
            assert(hit_level == 3)
        }
    }
--- request
GET /t
--- response_body
Test A: negative TTL return value for positive data bypasses cache
in positive callback
in positive callback
Test B: negative TTL return value for negative data bypasses cache
in negative callback
in negative callback
--- no_error_log
[error]



=== TEST 50: renew() always calls the callback when no errors have occurred prior
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc = {
                    register_listeners = function()
                    end,
                    broadcast = function(channel, data)
                        ngx.say("called ipc.broadcast() with args: ", channel, ":", data)
                    end,
                    poll = function(...)
                        return true
                    end,
                }
            }))

            local i = 0

            local function cb()
                i = i + 1
                ngx.say("in callback ", i)
                return i
            end

            local data, err, ttl = cache:renew("key", opts, cb)
            assert(err == nil, err)
            assert(data == 1)
            assert(ttl == 30)

            data, err, ttl = cache:renew("key", opts, cb)
            assert(err == nil, err)
            assert(data == 2)
            assert(ttl == 30)

            data, err, ttl = cache:renew("key", opts, cb)
            assert(err == nil, err)
            assert(data == 3)
            assert(ttl == 30)
        }
    }
--- request
GET /t
--- response_body
in callback 1
called ipc.broadcast() with args: mlcache:invalidations:my_mlcache:key
in callback 2
called ipc.broadcast() with args: mlcache:invalidations:my_mlcache:key
in callback 3
called ipc.broadcast() with args: mlcache:invalidations:my_mlcache:key
--- no_error_log
[error]
