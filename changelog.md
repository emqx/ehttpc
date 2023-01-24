# ehttpc changes

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
