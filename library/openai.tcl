# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

package require Tcl 8.6-
package require trequests 1.2
package require tjson 1.0.27
source [file join [file dirname [info script]] sse.tcl]

namespace eval ::openai {
    namespace export Client output_text token_usage
}

proc ::openai::get {value args} {
    if {[dict exists $value {*}$args]} {return [dict get $value {*}$args]}
    return {}
}
proc ::openai::options {defaults args} {
    if {[llength $args] % 2} {error "Options require name/value pairs"}
    foreach {key value} $args {
        if {![dict exists $defaults $key]} {error "Unknown option: $key"}
        dict set defaults $key $value
    }
    return $defaults
}
proc ::openai::boolean {value} {
    if {![string is boolean -strict $value]} {error "Expected a boolean, got: $value"}
    return [expr {!!$value}]
}
proc ::openai::object_json {json} {
    set typed [::tjson::json_to_typed $json]
    if {[lindex $typed 0] ne "M"} {error "Expected a JSON object"}
    return [lindex $typed 1]
}
# Tcl 8.6 uses a different internal representation for non-BMP characters.
# Normalize cJSON's decoded Unicode, including escaped surrogate pairs.
proc ::openai::decode {json} {
    set value [::tjson::json_to_simple $json]
    return [encoding convertfrom utf-8 [encoding convertto utf-8 $value]]
}
proc ::openai::validate_typed {spec} {
    if {[llength $spec] != 2} {error "JSON values require a type/value pair"}
    lassign $spec type value
    switch -- $type {
        S {
            if {[string first "\x00" $value] >= 0} {error "Embedded NUL is not supported by tjson strings"}
        }
        BOOL {boolean $value}
        N {
            if {![regexp {^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$} $value] ||
                ![string is double -strict $value] || abs(double($value)) == Inf} {
                error "Invalid JSON number: $value"
            }
        }
        M {dict for {key child} $value {validate_typed [list S $key]; validate_typed $child}}
        L {foreach child $value {validate_typed $child}}
        default {error "Unknown JSON type: $type (use -json for JSON null)"}
    }
}
proc ::openai::body_json {json endpoint stream} {
    # Mutate the parsed tree instead of converting raw input to typed Tcl:
    # tjson's typed conversion represents JSON null as an empty string.
    object_json $json
    set root [::tjson::parse $json]
    try {
        if {[::tjson::has_object_item $root stream]} {
            ::tjson::replace_item_in_object $root stream [list BOOL $stream]
        } else {::tjson::add_item_to_object $root stream [list BOOL $stream]}
        if {$endpoint eq "responses" && ![::tjson::has_object_item $root store]} {
            ::tjson::add_item_to_object $root store {BOOL 0}
        }
        if {$stream && $endpoint eq "chat/completions" && ![::tjson::has_object_item $root stream_options]} {
            ::tjson::add_item_to_object $root stream_options {M {include_usage {BOOL 1}}}
        }
        set result [::tjson::to_json $root]
        return [encoding convertfrom utf-8 [encoding convertto utf-8 $result]]
    } finally {::tjson::destroy $root}
}
proc ::openai::output_text {response} {
    if {[dict exists $response choices]} {
        set text {}
        foreach choice [dict get $response choices] {
            append text [get $choice message content]
        }
        return $text
    }
    set text {}
    foreach item [get $response output] {
        if {[get $item type] ne "message"} continue
        foreach part [get $item content] {
            if {[get $part type] eq "output_text"} {append text [get $part text]}
        }
    }
    return $text
}
proc ::openai::token_usage {response} {
    set usage [get $response usage]
    if {$usage eq {}} {return {}}
    set result [dict create input_tokens 0 output_tokens 0 total_tokens 0 \
        cached_input_tokens 0 reasoning_tokens 0]
    foreach {target paths} {
        input_tokens {{input_tokens} {prompt_tokens}}
        output_tokens {{output_tokens} {completion_tokens}}
        total_tokens {{total_tokens}}
        cached_input_tokens {{input_tokens_details cached_tokens} {prompt_tokens_details cached_tokens} {prompt_cache_hit_tokens}}
        reasoning_tokens {{output_tokens_details reasoning_tokens} {completion_tokens_details reasoning_tokens}}
    } {
        foreach path $paths {
            if {[dict exists $usage {*}$path]} {
                dict set result $target [dict get $usage {*}$path]
                break
            }
        }
    }
    return $result
}

# All HTTP operations use the asynchronous transport. Synchronous methods wait
# on the same request object, so data callbacks and Tcl timers remain active.
oo::class create ::openai::Client {
    variable config session requests closing
    constructor {args} {
        set session {}; set requests {}; set closing 0
        set key {}
        if {[info exists ::env(OPENAI_API_KEY)]} {set key $::env(OPENAI_API_KEY)}
        set config [::openai::options [dict create -api_key $key \
            -base_url https://api.openai.com/v1 -timeout 900000 \
            -timeout_connect 10000 -cafile {} -max_event_bytes 8388608 \
            -max_response_bytes 67108864] {*}$args]
        if {[dict get $config -api_key] eq {}} {error "An API key is required"}
        foreach key {-timeout -timeout_connect -max_event_bytes -max_response_bytes} {
            set value [dict get $config $key]
            if {![string is integer -strict $value] || $value <= 0} {error "$key must be a positive integer"}
        }
        set base [string trimright [dict get $config -base_url] /]
        if {![regexp {^https?://[^/?#]+(?:/[^?#]*)?$} $base]} {
            error "-base_url must be an HTTP(S) URL without query or fragment"
        }
        dict set config -base_url $base
        set opts [list -headers [dict create Authorization "Bearer [dict get $config -api_key]" \
            User-Agent openai-sdk-tcl/0.1.0] -allow_redirects false \
            -timeout [dict get $config -timeout] -timeout_connect [dict get $config -timeout_connect]]
        if {[dict get $config -cafile] ne {}} {lappend opts -cafile [dict get $config -cafile]}
        set session [::trequests::session {*}$opts]
    }
    destructor {
        set closing 1
        foreach request $requests {if {[info object isa object $request]} {$request destroy}}
        if {$session ne {}} {catch {$session destroy}}
    }
    method forget {request} {
        set index [lsearch -exact $requests $request]
        if {$index >= 0} {set requests [lreplace $requests $index $index]}
    }
    method responses {args} {my request responses {*}$args}
    method chat_completions {args} {my request chat/completions {*}$args}
    method request {endpoint args} {
        if {$closing} {error "Client is closing"}
        set opts [::openai::options [dict create -model {} -input {} -messages {} \
            -json {} -parameters {} -stream false -async false -on_event {} -on_done {}] {*}$args]
        set stream [::openai::boolean [dict get $opts -stream]]
        set async [::openai::boolean [dict get $opts -async]]
        foreach key {-on_event -on_done} {llength [dict get $opts $key]}
        if {!$async && [dict get $opts -on_done] ne {}} {error "-on_done requires -async true"}
        if {!$stream && [dict get $opts -on_event] ne {}} {error "-on_event requires -stream true"}
        if {[dict get $opts -json] ne {}} {
            if {[dict get $opts -parameters] ne {}} {error "Use either -json or -parameters"}
            foreach key {-model -input -messages} {
                if {[dict get $opts $key] ne {}} {error "-json cannot be combined with $key"}
            }
            set json [dict get $opts -json]
        } else {
            set fields [dict get $opts -parameters]
            dict size $fields
            if {[dict get $opts -model] eq {}} {error "-model is required"}
            dict set fields model [list S [dict get $opts -model]]
            if {$endpoint eq "responses"} {
                if {[dict get $opts -messages] ne {}} {error "Use -input with responses"}
                dict set fields input [list S [dict get $opts -input]]
            } else {
                if {[dict get $opts -input] ne {}} {error "Use -messages with chat_completions"}
                set messages {}
                foreach message [dict get $opts -messages] {
                    foreach key {role content} {dict get $message $key}
                    set fieldsMessage {}
                    dict for {key value} $message {
                        if {$key ni {role content name tool_call_id}} {
                            error "Complex messages require -json (unsupported field: $key)"
                        }
                        dict set fieldsMessage $key [list S $value]
                    }
                    lappend messages [list M $fieldsMessage]
                }
                if {![llength $messages]} {error "-messages must contain at least one message"}
                dict set fields messages [list L $messages]
            }
        }
        if {[dict get $opts -json] eq {}} {
            ::openai::validate_typed [list M $fields]
            set json [::tjson::typed_to_json [list M $fields]]
        }
        set body [::openai::body_json $json $endpoint $stream]
        set request [::openai::Request new [self] $session $config $endpoint $body $opts]
        lappend requests $request
        if {$async} {return $request}
        try {
            $request wait
            return [$request result]
        } finally {
            if {[info object isa object $request]} {$request destroy}
        }
    }
}

oo::class create ::openai::Request {
    variable owner transport parser state value failure errorOptions options endpoint
    variable httpStatus responseHeaders terminal errorBody buffer maxBytes received
    variable choices metadata usage notified notifyToken disposed
    constructor {client session config api body opts} {
        set owner $client; set transport {}; set parser {}; set disposed 0
        set state pending; set value {}; set failure {}; set errorOptions {}
        set options $opts; set endpoint $api; set terminal 0; set errorBody {}; set buffer {}
        set httpStatus 0; set responseHeaders {}; set received 0
        set choices {}; set metadata {}; set usage {}; set notified 0; set notifyToken {}
        set maxBytes [dict get $config -max_response_bytes]
        if {[dict get $options -stream]} {
            set parser [::openai::SSE new [list [self] event] [dict get $config -max_event_bytes]]
        }
        set accept [expr {$parser eq {} ? "application/json" : "text/event-stream"}]
        set transport [$session post "[dict get $config -base_url]/$api" \
            -async -data_binary [encoding convertto utf-8 $body] \
            -content_type application/json -accept $accept -buffer_response false \
            -callback_data [list [self] data] -callback [list [self] completed]]
    }
    destructor {
        set disposed 1
        if {$notifyToken ne {}} {after cancel $notifyToken}
        if {$transport ne {}} {catch {$transport destroy}}
        if {$parser ne {}} {catch {$parser destroy}}
        if {[info object isa object $owner]} {$owner forget [self]}
        set state destroyed
    }
    method state {} {return $state}
    method http_status {} {return $httpStatus}
    method headers {} {return $responseHeaders}
    method result {} {
        if {$state eq "pending"} {error "Request is still pending"}
        if {$state ne "done"} {return -options $errorOptions $failure}
        return $value
    }
    method wait {} {
        while {$state eq "pending"} {vwait [namespace which -variable state]}
        return $state
    }
    method cancel {} {
        if {$state eq "pending"} {
            my fail "Request cancelled" [dict create -code 1 -level 0 -errorcode {OPENAI CANCELLED}] cancelled
        }
    }
    method fail {message opts {newState error}} {
        if {$state ne "pending"} return
        set failure $message; set errorOptions $opts
        dict set errorOptions -code 1; dict set errorOptions -level 0
        my finish $newState
    }
    method finish {newState} {
        set state $newState
        if {$transport ne {}} {catch {$transport destroy}; set transport {}}
        if {[dict get $options -on_done] ne {}} {
            set notifyToken [after 0 [list [self] notify]]
        }
    }
    method notify {} {
        set notifyToken {}
        if {$notified || $disposed} return
        set notified 1
        {*}[dict get $options -on_done] [self]
    }
    method emit {event} {
        if {[dict get $options -on_event] ne {}} {{*}[dict get $options -on_event] $event}
    }
    method data {bytes handle} {
        if {$state ne "pending"} return
        try {
            set httpStatus [$handle status_code]
            set responseHeaders [$handle headers]
            if {$httpStatus < 200 || $httpStatus >= 300} {
                if {[string length $errorBody] < 65536} {
                    append errorBody [string range $bytes 0 [expr {65535 - [string length $errorBody]}]]
                }
                return
            }
            incr received [string length $bytes]
            if {$received > $maxBytes} {throw {OPENAI LIMIT} "Response exceeds $maxBytes bytes"}
            if {$parser ne {}} {
                set contentType [lindex [$handle header Content-Type] 0]
                if {![string equal -nocase [string trim [lindex [split $contentType {;}] 0]] text/event-stream]} {
                    throw {OPENAI PROTOCOL} "Expected text/event-stream, received $contentType"
                }
                $parser feed $bytes
            } else {
                append buffer $bytes
            }
        } on error {message opts} {
            if {!$disposed && $state eq "pending"} {my fail $message $opts}
        }
    }
    method event {name json} {
        if {$disposed || $state ne "pending"} return
        if {$terminal} {error "Received data after stream completion"}
        if {$json eq {[DONE]}} {
            if {$endpoint ne "chat/completions"} {error "Unexpected [format %s {[DONE]}] in Responses stream"}
            set terminal 1
            my assembleChat
            return
        }
        ::openai::object_json $json
        set event [::openai::decode $json]
        if {$endpoint eq "chat/completions"} {
            if {[dict exists $event error]} {error [my errorMessage $event]}
            my chatEvent $event $json
            return
        }
        set type [::openai::get $event type]
        if {$type eq {}} {set type $name}
        dict set event type $type
        dict set event raw_json $json
        switch -- $type {
            response.completed {
                set value [dict get $event response]
                set terminal 1
            }
            response.failed - response.incomplete - error - response.error {
                set details $event
                if {[dict exists $event response]} {set details [dict get $event response]}
                return -code error -errorcode [list OPENAI API $type] [my errorMessage $details]
            }
        }
        my emit $event
    }
    method errorMessage {body} {
        set message [::openai::get $body error message]
        if {$message eq {}} {set message [::openai::get $body message]}
        if {$message eq {}} {set message [::openai::get $body incomplete_details reason]}
        if {$message eq {}} {set message "API response failed or was incomplete"}
        return $message
    }
    method chatEvent {chunk json} {
        foreach field {id model created system_fingerprint service_tier} {
            if {[dict exists $chunk $field]} {dict set metadata $field [dict get $chunk $field]}
        }
        if {[::openai::get $chunk usage] ne {}} {set usage [dict get $chunk usage]}
        foreach choice [::openai::get $chunk choices] {
            set index [dict get $choice index]
            if {![string is integer -strict $index] || $index < 0} {error "Invalid choice index"}
            if {![dict exists $choices $index]} {
                dict set choices $index [dict create index $index message [dict create role assistant content {}] \
                    finish_reason {} tools {}]
            }
            set current [dict get $choices $index]
            if {[::openai::get $choice finish_reason] ne {}} {
                dict set current finish_reason [dict get $choice finish_reason]
            }
            set delta [::openai::get $choice delta]
            foreach field {role content refusal reasoning_content} {
                if {[dict exists $delta $field] && [dict get $delta $field] ne {}} {
                    set text [dict get $delta $field]
                    if {$field eq "role"} {
                        dict set current message role $text
                    } else {
                        dict set current message $field "[::openai::get $current message $field]$text"
                    }
                }
            }
            foreach tool [::openai::get $delta tool_calls] {
                set toolIndex [::openai::get $tool index]
                if {$toolIndex eq {}} {
                    set id [::openai::get $tool id]
                    set toolIndex {}
                    dict for {existing record} [dict get $current tools] {
                        if {$id ne {} && [::openai::get $record id] eq $id} {set toolIndex $existing; break}
                    }
                    if {$toolIndex eq {}} {
                        if {$id ne {}} {
                            set toolIndex 0
                            foreach existing [dict keys [dict get $current tools]] {
                                if {$existing >= $toolIndex} {set toolIndex [expr {$existing + 1}]}
                            }
                        } elseif {[dict size [dict get $current tools]] == 1} {
                            set toolIndex [lindex [dict keys [dict get $current tools]] 0]
                        } else {error "Ambiguous tool-call delta without index or id"}
                    }
                }
                if {![string is integer -strict $toolIndex] || $toolIndex < 0} {error "Invalid tool-call index"}
                set record [::openai::get $current tools $toolIndex]
                foreach field {id type} {
                    if {[::openai::get $tool $field] ne {}} {dict set record $field [dict get $tool $field]}
                }
                foreach field {name arguments} {
                    if {[dict exists $tool function $field]} {
                        dict set record function $field "[::openai::get $record function $field][dict get $tool function $field]"
                    }
                }
                dict set current tools $toolIndex $record
            }
            dict set choices $index $current
        }
        my emit [dict create type chat.completion.chunk raw $chunk raw_json $json]
        if {$disposed || $state ne "pending"} return
        foreach choice [::openai::get $chunk choices] {
            foreach {field type} {content response.output_text.delta reasoning_content response.reasoning_text.delta} {
                set text [::openai::get $choice delta $field]
                if {$text ne {}} {
                    my emit [dict create type $type delta $text choice_index [dict get $choice index] \
                        response_id [::openai::get $chunk id] raw $chunk raw_json $json]
                    if {$disposed || $state ne "pending"} return
                }
            }
        }
    }
    method assembleChat {} {
        if {![dict size $choices]} {error "Chat stream completed without choices"}
        set value $metadata
        dict set value object chat.completion
        set assembled {}
        foreach index [lsort -integer [dict keys $choices]] {
            set choice [dict get $choices $index]
            if {[dict get $choice finish_reason] eq {}} {error "Chat stream ended without finish_reason"}
            set tools {}
            foreach toolIndex [lsort -integer [dict keys [dict get $choice tools]]] {
                lappend tools [dict get $choice tools $toolIndex]
            }
            if {[llength $tools]} {dict set choice message tool_calls $tools}
            dict unset choice tools
            lappend assembled $choice
        }
        dict set value choices $assembled
        if {$usage ne {}} {dict set value usage $usage}
    }
    method completed {handle} {
        if {$state ne "pending"} return
        try {
            set httpStatus [$handle status_code]
            set responseHeaders [$handle headers]
            if {[$handle state] eq "error"} {
                throw {OPENAI TRANSPORT} [$handle error]
            }
            if {$httpStatus < 200 || $httpStatus >= 300} {
                set message "HTTP $httpStatus"
                if {![catch {set body [::openai::decode [encoding convertfrom utf-8 $errorBody]]}]} {
                    append message ": [my errorMessage $body]"
                }
                throw [list OPENAI HTTP $httpStatus] $message
            }
            if {$parser ne {}} {
                $parser finish
                if {!$terminal} {throw {OPENAI TRUNCATED} "Stream ended before completion"}
            } else {
                set json [encoding convertfrom utf-8 $buffer]
                if {[encoding convertto utf-8 $json] ne $buffer} {error "Invalid UTF-8 in response"}
                ::openai::object_json $json
                set value [::openai::decode $json]
                if {[dict exists $value error] && [dict get $value error] ne {}} {error [my errorMessage $value]}
            }
            my finish done
        } on error {message opts} {
            my fail $message $opts
        }
    }
}
package provide openai 0.1.0
