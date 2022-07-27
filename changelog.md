# ehttpc changes

## 0.3.0

* Changes on top of 0.2.1:

  - Prohibit the `retry` and `retry_timeout` options.

## 0.2.1

* Improvements and Bug Fixes

  - Add ehttpc:health_check/2.

## 0.2.0

* Major refactoring on top of 0.1.15
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
