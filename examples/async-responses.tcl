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
proc completed {request} {set ::finished 1}
set finished 0
try {
    set request [$client responses -model $model -input "Explain Tcl's event loop." \
        -stream true -async true -on_event printDelta -on_done completed]
    # The application can process other Tcl events while this request runs.
    vwait finished
    $request result
    puts ""
    $request destroy
} finally {
    $client destroy
}
