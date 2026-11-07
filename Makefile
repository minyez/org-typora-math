EMACS ?= emacs

.PHONY: test compile clean

test:
	$(EMACS) --batch -Q -L . --eval '(setq load-prefer-newer t)' \
		-l test/org-typora-math-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile org-typora-math.el

clean:
	rm -f org-typora-math.elc
