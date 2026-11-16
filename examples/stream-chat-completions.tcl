# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

package require openai 0.1
if {![info exists ::env(OPENAI_MODEL)]} {error "Set OPENAI_MODEL to a model available to your account"}
set client [::openai::Client new]
set model $::env(OPENAI_MODEL)
proc printDelta {event} {
    if {[dict get $event type] eq "response.output_text.delta"} {
        puts -nonewline [dict get $event delta]
        flush stdout
    }
}
try {
    set response [$client chat_completions -model $model \
        -messages [list [dict create role user content "Explain Tcl in three sentences."]] \
        -stream true -on_event printDelta]
    puts ""
    puts stderr "Usage: [::openai::token_usage $response]"
} finally {
    $client destroy
}
