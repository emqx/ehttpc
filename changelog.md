# ehttpc changes

## 0.4.15

- Added support for using HTTP proxy (HTTP 1.1 only).
  To use it, pass `proxy` in the pool opts.

  Ex:

  ```erlang
  %% Point to the proxy host and port
  ProxyOpts = #{host => "127.0.0.1", port => 8888}.
  ehttpc_sup:start_pool(<<"pool">>, [{host, "target.host.com"}, {port, 80}, {proxy, ProxyOpts}]).

  %% To use username and password
  ProxyOpts = #{host => "127.0.0.1", port => 8888, username => "proxyuser", password => "secret"}.
  ehttpc_sup:start_pool(<<"pool">>, [{host, "target.host.com"}, {port, 80}, {proxy, ProxyOpts}]).
  ```

## 0.4.14

- Forcefully recreate `gproc_pool`s during `ehttpc_pool:init/1` to prevent reusing pools in an inconsistent state.

## 0.4.13

- Upgrade to gun 1.3.11.
  [Fix `host` header](https://github.com/emqx/gun/pull/8)

## 0.4.12

- Upgrade to gun 1.3.10 (OTP 26)
- Changed from `gun:open` to `gun:start_link` to start the gun process.
  This makes the gun process linked to `ehttpc` process (instead of `gun_sup`).
  Prior to this change, some early errors causing gun process to crash might not be able to be caught by ehttpc due to the slow monitoring.
  e.g. when some SSL option is invalid, the gun process will crash immediately and `ehttpc` can only get a `noproc` error reason from the delayed process monitor.

## 0.4.11

- Added support for `PATCH` method requests.

## 0.4.10

- Fixed `ehttpc:request` and `ehttpc:request_async` to handle `Timeout = infinity` option.

## 0.4.9

- Expanded the fix from 0.4.8 to also account for `{error, {shutdown, normal}}` return values in requests, and added a similar retry when the health check also fails with those two reasons.

## 0.4.8

- Fix an issue where a race condition would yield an `{error, normal}` return value.  This can be caused when the `gun` process terminates when the remote server closes the connection for whatever reason.  In this case, we simply retry without consuming "retry credits".

## 0.4.7

- Fix crash when using body headers and no body. When one sent a message with, for example, the content-type header and no body, the underlying gun library would expect a body to come with a gun:data/3 call and would not finish the request. The next request would then crash. See the following issue for more information: https://github.com/ninenines/gun/issues/141

## 0.4.6

- Fix a bug introduced in 0.4.5: `badarg` crash from `grpoc` when `pool_type` is `hash`.

## 0.4.5

- Make possible to start pool with `any()` name (not limited to `atom()`).

## 0.4.4

- Fix the issue that ehttpc opens a new client when an existing client has been
  opened but not ready (no `gun_up` received).

## 0.4.3

- Update `gproc` dependency to 0.9.0.
- Add `format_status/1` for OTP 25.

## 0.4.2

- Do not crash on `retry` and `retry_timeout` options.
  They might be persisted somehere, e.g. in an old config, or supervisor's child spec etc.

## 0.4.1

- Avoid sending stream cancellation messages to the 'gun' process if the stream is already finished ('fin' received)
- Force kill pool workers after 5 seconds waiting for graceful shutdown

## 0.4.0

- Add async APIs

## 0.3.0

- Changes on top of 0.2.1:

  - Prohibit the `retry` and `retry_timeout` options.

## 0.2.1

- Improvements and Bug Fixes

  - Add ehttpc:health_check/2.

## 0.2.0

- Major refactoring on top of 0.1.15
  - Added test cases.
  - Support hot upgrade from all 0.1.X versions.
  - No lower level retry (in 'gun' the http client lib).
  - Now `enable_pipelining` can be an integer to indicate the number of HTTP requests
    can be sent on wire before receiving responses (like the inflight-window).
    `enable_pipelining=true` has the same effect as `enable_pipelining=100` and
    `enable_pipelining=false` has the same effect as `enable_pipelining=1`
  - Now all requests are async, so the `ehttpc:request` calls can be collected
    from mailbox into process state, this makes the handling of gun responses
    more effecient.

## 0.1.14

- fixed appup. old versions missed ehttpc_pool
- added check_vsn.escript to sure version consistent and run in ci
