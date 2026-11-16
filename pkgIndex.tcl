# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

if {![package vsatisfies [package provide Tcl] 8.6-]} {return}
package ifneeded openai 0.1.0 [list source [file join $dir library openai.tcl]]
