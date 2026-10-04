LISP := /home/arthur/repos/sb-simd-512/run-sbcl.sh

LISPFLAGS := --noinform --no-userinit --non-interactive

ifeq ($(OS), Windows_NT)
    PROGRAM := wc.exe
else
    PROGRAM := wc
endif

TESTS_DIR := tests
TOOLS_DIR := tools

# Test data isn't kept in the repo (see .gitignore) -- TEST-DATA below
# regenerates it from the small checked-in seed file by repeating it
# with tools/append-file.cl. 280 repeats of plato.org (~3.8 MB) lands
# just over 1 GiB; adjust if a different test-file size is wanted.
TEST-SEED := $(TESTS_DIR)/plato.org
TEST-DATA := $(TESTS_DIR)/plato1g.txt
TEST-DATA-REPEAT := 280

.PHONY: all test clean

all: $(PROGRAM)

$(PROGRAM):
	$(LISP) $(LISPFLAGS) \
		--eval '(require :asdf)' \
		--eval '(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))' \
		--eval '(push (uiop:getcwd) asdf:*central-registry*)' \
		--eval '(asdf:make "wordcount")'

$(TEST-DATA): $(TEST-SEED) $(TOOLS_DIR)/append-file.cl
	rm -f $@
	$(LISP) $(LISPFLAGS) \
		--eval '(require :asdf)' \
		--load $(TOOLS_DIR)/append-file.cl \
		--eval '(append-file:append-file "$(TEST-SEED)" "$(TEST-DATA)" :repeat-count $(TEST-DATA-REPEAT))'

test: $(TEST-DATA)
	$(LISP) $(LISPFLAGS) --load $(TESTS_DIR)/test-avx512-kernels.lisp

clean:
	rm -f *.fasl src/*.fasl $(TESTS_DIR)/*.fasl $(PROGRAM)
