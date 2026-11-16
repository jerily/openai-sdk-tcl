<!--
/**
 * Copyright Jerily LTD. All Rights Reserved.
 * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
 * SPDX-License-Identifier: MIT.
 */
-->

# openai-sdk-tcl

An MIT-licensed Tcl client for OpenAI Responses and Chat Completions, including
incremental SSE streaming. The SDK is Tcl code; HTTP and JSON use the native
[trequests](https://github.com/jerily/trequests) and
[tjson](https://github.com/jerily/tjson) packages. No SDK compilation is required.

## Install

Requires Tcl 8.6 or 9.x, trequests 1.2.0 or newer compatible 1.x, and tjson
1.0.27 or newer compatible 1.x. Build native dependencies for your Tcl major version.

```sh
ttrek init -y
ttrek install openai-sdk-tcl
```

For a source checkout, install its dependencies with `ttrek install`, or make
them available on Tcl's `auto_path`, then install the SDK:

```sh
make install PREFIX=/your/prefix
```

Add `/your/prefix/lib` to `TCLLIBPATH` when it is outside Tcl's normal package
search path. For development, adding the checkout directory to `auto_path` is
sufficient. `ttrek.json` includes the dependency and installation recipe.

## Quick start

Set `OPENAI_API_KEY` and `OPENAI_MODEL` in your environment. Select a model
available to your account that supports the endpoint you use.

```tcl
package require openai 0.1
set client [::openai::Client new]
try {
    set response [$client responses -model $::env(OPENAI_MODEL) \
        -input "Explain Tcl in three sentences."]
    puts [::openai::output_text $response]
    puts [::openai::token_usage $response]
} finally {
    $client destroy
}
```

`chat_completions` accepts a list of message dictionaries:

```tcl
set response [$client chat_completions -model $::env(OPENAI_MODEL) \
    -messages [list [dict create role user content "Hello!"]]]
```

The simple message builder supports string fields `role`, `content`, `name`,
and `tool_call_id`. Use `-json` for multimodal input, assistant tool calls,
nullable content, and other complex messages.

## Streaming

Both methods accept `-stream true -on_event commandPrefix`. The synchronous
call runs Tcl's event loop, invokes callbacks as data arrives, and returns the
final API response. Streaming does not require a separate thread or process.

```tcl
proc printDelta {event} {
    if {[dict get $event type] eq "response.output_text.delta"} {
        puts -nonewline [dict get $event delta]
        flush stdout
    }
}
set response [$client responses -model $::env(OPENAI_MODEL) \
    -input "Explain Tcl's event loop." -stream true -on_event printDelta]
puts ""
```

Responses events retain their original fields and add `raw_json`. The final
result comes from `response.completed`. Failed and incomplete Responses events
raise an error. Unknown event types are passed through for forward compatibility.

Chat streams emit `chat.completion.chunk` with `raw` (the parsed chunk) and
`raw_json`. Text and provider-supplied reasoning deltas also emit
`response.output_text.delta` and `response.reasoning_text.delta`, with `delta`,
`choice_index`, `response_id`, `raw`, and `raw_json`. Accumulation keeps choices
and interleaved function tool calls separate. Tool fragments are available in
`chat.completion.chunk`; the SDK never executes tools. The final result is a
synthesized chat-completion dictionary, including finish reasons and usage when
provided. `[DONE]` and per-choice finish reasons are required for success.
`stream_options.include_usage` defaults to true for Chat Completions; pass an
explicit `stream_options` object for providers that do not support it.

To avoid waiting in a server handler, use an asynchronous request:

```tcl
proc finished {request} {set ::finished 1}
set finished 0
set request [$client responses -model $::env(OPENAI_MODEL) -input "Hello!" \
    -stream true -async true -on_event printDelta -on_done finished]
try {
    vwait finished
    set response [$request result]
} finally {
    $request destroy
}
```

A server already running the Tcl event loop can process the result directly in
`-on_done`; it does not need `vwait`. Callbacks are Tcl command prefixes, invoked
at global scope. Keep callbacks short. Synchronous SDK calls also process other
Tcl events, so account for event-loop reentrancy in application state.

Request methods:

| Method | Result |
| --- | --- |
| `state` | `pending`, `done`, `error`, or `cancelled` |
| `wait` | Wait through the event loop and return the terminal state |
| `result` | Return the final dictionary, or raise the saved error |
| `http_status` | HTTP status, or zero before available |
| `headers` | Response header list as returned by trequests |
| `cancel` | Cancel locally and schedule the completion callback once |
| `destroy` | Free the request and suppress remaining callbacks |

Destroying the client destroys its outstanding requests. Local cancellation
closes the HTTP transfer; it does not call the Responses cancellation endpoint
or guarantee that server-side generation has stopped. Callback exceptions fail
the request and are rethrown by `result`; completion-callback exceptions follow
Tcl's background-error behavior. Retrying is an explicit caller decision.

## Options and JSON

Client options:

| Option | Default |
| --- | --- |
| `-api_key` | `OPENAI_API_KEY` |
| `-base_url` | `https://api.openai.com/v1` |
| `-timeout` | 900000 milliseconds for the transfer |
| `-timeout_connect` | 10000 milliseconds |
| `-cafile` | libcurl's configured CA trust store |
| `-max_event_bytes` | 8388608 bytes per SSE event |
| `-max_response_bytes` | 67108864 total response bytes, streamed or buffered |

TLS peer and hostname verification stay enabled. Redirects are disabled. An
HTTP base URL is supported for local tests and compatible local servers.

Request options are `-model`, `-input` (Responses), `-messages` (Chat Completions),
`-json`, `-parameters`, `-stream`, `-async`, `-on_event`, and `-on_done`.
Boolean options take explicit Tcl booleans. Requests are non-streaming and
synchronous by default. `-on_done` requires `-async true`; `-on_event` requires
`-stream true`.

`-parameters` adds API fields using tjson's typed values (`S`, `N`, `BOOL`, `M`,
`L`), preserving strings, numbers, booleans, objects, and arrays:

```tcl
set response [$client responses -model $::env(OPENAI_MODEL) -input "Hello" \
    -parameters {max_output_tokens {N 256} store {BOOL 0}}]
```

Use `-json` instead of `-model`, `-input`, `-messages`, and `-parameters` to
supply a complete JSON request, including tools and structured-output schemas.
The SDK sets the top-level `stream` field from `-stream`; all other raw fields
are preserved, including JSON null. Responses default to `store=false` unless
explicitly supplied. Model-specific reasoning or verbosity fields are not added
automatically. The base URL can target compatible providers.

Returned JSON uses tjson's simple Tcl mapping: objects become dictionaries,
arrays become lists, booleans become 0/1, and null becomes an empty string.
Streaming events retain `raw_json` when exact JSON types matter. tjson does not
support embedded NUL characters in strings; the simple request builder rejects
them. Supply JSON null through `-json`, rather than typed parameters.

`::openai::output_text` concatenates Responses message output text or Chat
Completions choice content. For multiple choices, inspect `choices` separately.
`::openai::token_usage` returns input, output, total, cached-input, and reasoning
token counts, or an empty dictionary when usage is absent. Missing detail counts
are zero; unavailable overall usage is never invented.

HTTP failures raise `OPENAI HTTP <status>` with the API error message when
available. Transport failures use `OPENAI TRANSPORT`; cancellation uses
`OPENAI CANCELLED`; missing terminal events use `OPENAI TRUNCATED`. Other parser
and callback errors retain their Tcl error details. Stream framing errors,
invalid JSON, size-limit violations, and premature EOF never become success.

## Examples

- [Chat Completions](examples/chat-completions.tcl)
- [Responses](examples/responses.tcl)
- [Streaming Chat Completions](examples/stream-chat-completions.tcl)
- [Streaming Responses](examples/stream-responses.tcl)
- [Asynchronous streaming Responses](examples/async-responses.tcl)

After installing the package, run these scripts from your consuming project:

```sh
export OPENAI_API_KEY=your-api-key
export OPENAI_MODEL=your-model

ttrek run -package openai-sdk-tcl -script example-responses
ttrek run -package openai-sdk-tcl -script example-chat-completions
ttrek run -package openai-sdk-tcl -script example-stream-responses
ttrek run -package openai-sdk-tcl -script example-stream-chat-completions
ttrek run -package openai-sdk-tcl -script example-async-responses
```

Pass a custom prompt after `--`, for example:

```sh
ttrek run -package openai-sdk-tcl -script example-stream-responses -- "What is Tcl?"
```

The scripts load the installed SDK, print generated text and token usage, and
exit with an error if the request fails. They use your project's Tcl interpreter;
set `TCLSH` to select one explicitly. Optionally set `OPENAI_BASE_URL` for a
compatible API endpoint. With the default endpoint, these make real OpenAI API
requests using your key.

If you installed before the example scripts were added, refresh the registry
and installed script metadata:

```sh
ttrek sync
ttrek install -force openai-sdk-tcl
```

In a source checkout, use `ttrek run -script example-responses`, or run the
individual Tcl files with your dependency paths configured, for example
`tclsh examples/stream-responses.tcl`.

## Embedding

Build trequests with `-DBUILD_SHARED_LIBS=OFF` and link its archive with Tcl and
libcurl (including libcurl's own dependencies). Register `Trequests_Init` with
`Tcl_StaticPackage` on Tcl 8.6 or `Tcl_StaticLibrary` on Tcl 9. Do the same for
`Tjson_Init`. Initialize them in each interpreter, or use `load {} Trequests`
and `load {} Tjson` after registering them. Their initialization provides the
packages required by this SDK. Ship `pkgIndex.tcl` and `library/` on `auto_path`,
or source `library/openai.tcl` from embedded resources. The SDK has no shared
library of its own.

## Development notes

The HTTP layer belongs to trequests; endpoint behavior, JSON construction, SSE
framing, and final-result accumulation live here. Each request owns its parser
and state. SSE parsing handles LF, CRLF, CR, BOMs, comments, multiline data, and
arbitrary chunk/UTF-8 splits. Raw bodies are not retained in addition to stream
state. HTTP error excerpts are capped at 64 KiB. The total response limit also
bounds accumulated text/tool arguments. trequests separately bounds queued
body callbacks to 1 MiB and reports overflow explicitly.

Run the offline tests from a source checkout with native dependencies on
`auto_path`:

```sh
make test TCLSH=tclsh8.6
make test TCLSH=tclsh9.1
```

Tests use Python 3's standard-library HTTP server on loopback and Tcl's
`tcltest`; no API key or external service is needed. Coverage includes request
serialization, Unicode, JSON null, both APIs and streaming forms, concurrent
requests, interleaved tool calls, usage, truncated/error streams, callback
exceptions, cancellation, size limits, and destruction during callbacks.

Release validation: all 22 offline SDK tests pass on Tcl 8.6 and 9.1, including
an embedded Tcl 9.1 host with static trequests and tjson archives. The transport
suite passes on both Tcl versions and under AddressSanitizer/UBSan (leak
detection disabled). Shared and static registry recipes generate valid shell
scripts. No live OpenAI request is part of release validation.

Package example validation: all five named scripts run from a separate consuming
project on Tcl 8.6 and 9.1 with a local mock API, including Unicode prompts and
streamed output. HTTP failures and missing configuration return a nonzero exit
status. Installed scripts also run with the registry unavailable.
