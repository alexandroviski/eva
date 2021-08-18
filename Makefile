# for a guide: https://nullprogram.com/blog/2020/01/22/
.POSIX:
.SUFFIXES: .el .elc
EMACS	= emacs
EL   	= ass.el ass-config.el ass-builtin.el ass-doing.el
ELC  	= $(EL:.el=.elc)
# external dependencies
LDFLAGS = -L deps/ts -L deps/dash -L deps/s -L deps/ess/lisp -L deps/f -L deps/named-timer -L deps/pfuture -L deps/transient/lisp

# default make action to run frequently during devel
compile-and-clean: clean $(ELC) test
	rm -f $(ELC) ass-test.elc

# $ELC expands to .elc versions of all files listed in $EL.
compile: $(ELC)

check: ass-test.elc
	$(EMACS) -Q -L . $(LDFLAGS) --batch -l ass-test.elc -f ert-run-tests-batch

# alias
test: check

clean:
	rm -f $(ELC) ass-test.elc

# Dependencies
ass-test.elc:  $(ELC)
ass-config.elc: ass.elc ass-builtin.elc ass-doing.elc
ass-activity.elc: ass.elc ass-builtin.elc
ass-builtin.elc: ass.elc

# Tell make how to compile an .el into an .elc.
.el.elc:
	$(EMACS) -Q -L . $(LDFLAGS) --batch -f batch-byte-compile $<

# Clone the dependencies of this package:
# mkdir deps
# git clone --depth=1 https://github.com/alphapapa/ts.el deps/ts
# git clone --depth=1 https://github.com/magnars/dash.el deps/dash
# git clone --depth=1 https://github.com/magnars/s.el deps/s
# git clone --depth=1 https://github.com/emacs-ess/ess deps/ess
# git clone --depth=1 https://github.com/rejeep/f.el  deps/f
# git clone --depth=1 https://github.com/DarwinAwardWinner/emacs-named-timer  deps/named-timer
# git clone --depth=1 https://github.com/Alexander-Miller/pfuture  deps/pfuture
# git clone --depth=1 https://github.com/magit/transient deps/transient
# git clone --depth=1 https://github.com/ledger/ledger-mode deps/ledger-mode

# Not (yet) needed at compilation
# git clone --depth=1 https://github.com/ch11ng/exwm deps/exwm
# git clone --depth=1 https://github.com/bastibe/org-journal deps/org-journal
