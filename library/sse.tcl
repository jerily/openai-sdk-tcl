# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

namespace eval ::openai {}

# SSE framing operates on bytes; decoding happens only after a complete line.
oo::class create ::openai::SSE {
    variable pending event data skipLF firstLine eventBytes limit callback
    constructor {command {maxBytes 8388608}} {
        set pending {}; set event {}; set data {}; set skipLF 0
        set firstLine 1; set eventBytes 0; set limit $maxBytes
        set callback $command
    }
    method feed {bytes} {
        append pending $bytes
        while {[string length $pending]} {
            if {$skipLF} {
                set skipLF 0
                if {[string index $pending 0] eq "\n"} {
                    set pending [string range $pending 1 end]
                    continue
                }
            }
            if {![regexp -indices {[\r\n]} $pending match]} break
            set index [lindex $match 0]
            set bytes [string range $pending 0 $index-1]
            set skipLF [expr {[string index $pending $index] eq "\r"}]
            set pending [string range $pending $index+1 end]
            incr eventBytes [expr {$index + 1}]
            if {$eventBytes > $limit} {error "SSE event exceeds $limit bytes"}
            set line [encoding convertfrom utf-8 $bytes]
            if {[encoding convertto utf-8 $line] ne $bytes} {error "Invalid UTF-8 in SSE stream"}
            if {$firstLine} {
                set firstLine 0
                if {[string index $line 0] eq "\ufeff"} {set line [string range $line 1 end]}
            }
            if {$line eq {}} {
                set name [expr {$event eq {} ? "message" : $event}]
                set lines $data
                set event {}; set data {}; set eventBytes 0
                if {[llength $lines]} {{*}$callback $name [join $lines "\n"]}
                continue
            }
            if {[string index $line 0] eq ":"} continue
            set colon [string first : $line]
            if {$colon < 0} {
                set field $line; set value {}
            } else {
                set field [string range $line 0 $colon-1]
                set value [string range $line $colon+1 end]
                if {[string index $value 0] eq " "} {set value [string range $value 1 end]}
            }
            switch -- $field {
                event {set event $value}
                data {lappend data $value}
            }
        }
        if {[string length $pending] + $eventBytes > $limit} {
            error "SSE event exceeds $limit bytes"
        }
    }
    method finish {} {
        if {$pending ne {} || [llength $data]} {error "Truncated SSE event"}
    }
}
