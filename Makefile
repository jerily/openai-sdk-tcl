# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

PREFIX ?= /usr/local
DESTDIR ?=
TCLSH ?= tclsh
PACKAGE_DIR = $(DESTDIR)$(PREFIX)/lib/openai0.1.0

.PHONY: all test install
all:
	@echo "Tcl package: no compilation required. Run make install."
test:
	$(TCLSH) tests/all.tcl
install:
	install -d "$(PACKAGE_DIR)/library" "$(DESTDIR)$(PREFIX)/share/doc/openai-sdk-tcl/examples"
	install -m 644 pkgIndex.tcl "$(PACKAGE_DIR)/"
	install -m 644 library/*.tcl "$(PACKAGE_DIR)/library/"
	install -m 644 LICENSE readme.md "$(DESTDIR)$(PREFIX)/share/doc/openai-sdk-tcl/"
	install -m 644 examples/*.tcl "$(DESTDIR)$(PREFIX)/share/doc/openai-sdk-tcl/examples/"
