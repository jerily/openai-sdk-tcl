# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

package require openai 0.1
if {![info exists ::env(OPENAI_MODEL)]} {error "Set OPENAI_MODEL to a model available to your account"}
set client [::openai::Client new]
set model $::env(OPENAI_MODEL)
try {
    set response [$client responses -model $model \
        -input "Explain Tcl in three sentences."]
    puts [::openai::output_text $response]
    puts stderr "Usage: [::openai::token_usage $response]"
} finally {
    $client destroy
}
