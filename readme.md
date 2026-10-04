## About

This is just a playground and a WIP for me so please don't use for anything. I
was doing a bunch of experiments where I have tested how fast I can implement
the wordcounting program in Common Lisp, on SBCL. This is actually the synthesis
of tests; I will publish with time the tests themselves, as well as the notes I
wrote while doing them which are ~20k words, and that before I had avx512
backend in SBCL. I started in May, and it led me to implement support for avx512
in SBCL and it's higher-level intrinsics library. Parts of it, the hardware
support for the compiler and scheduler are accepted in SBCL, however, they don't
have the evec encoder so unfortunately this tests are not runnable on stock
SBCL. Mine is available, you will have to check it out yourself and build if you
would to run these tests. I rebase periodically to the live master branch.

To build these tests you can just run make, but you will to modify the makefile
and point it to the above mentioned compiler branch, if you are interested to
test it.

Once the wc program is build you can run it with the same options as GNU wc
program. I haven't tested to pipe in it, and some other less options might not
work as they should, but word, line and character counting should work with both
ascii and utf8.

To see the difference with avx512 and avx2 you will need a computer with actuall
hardware that supports avx512, such as Zen 5, otherwise if you run on emulated
avx512, in the best case you will see the same result as in avx2 backend, or
probably worse.

GNU wc program is not hard to beat at all, it is not even the contester in this
race. The fastest one, I know of is [fastlwc, written in
C++](https://github.com/expr-fi/fastlwc/). They do multithreading and use avx512
too.

When it comes to application speed, the lisp one is usually on par, or just
slightly slower when the entire process is loading. The speed difference
compared to C++ program is usually within +/-0,003, which is probably the noise.

TBH here, I haven't yet looked at their avx512 implementation, but I guess if
there is some difference in the algorithm the same can be implemented in both
programs. It really is not question of programming langauge difference, which
was partially what I wanted to proof. In other words, the motivation for this
was to show that Common Lisp can be just as fast as other programming
languages. 

The key to speed in this particular case is: vector processing via avx512 and using
pread to minimize system calls, re-using buffer and keeping it in L2 cache. For
this reason you can use --chunk-size and --number-threads options, so you can
experiment and find the "sweet spot". Om my Zen 5 laptop (10 cores, 20 threads),
the sweet spot is ~1 megabyte chunks and 8-10 threads. More threads will degrade
the performance, and bigger chunks will not fit into the cache for each thread.

The simplest test is of course time program:

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation avx2 --number-threads 1                                                23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,117s
user    0m0,075s
sys     0m0,041s

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation avx512 --number-threads 1                                              
23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,108s
user    0m0,073s
sys     0m0,035s

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation generic --number-threads 1 
23220400 195711880 1073979760  tests/plato1g.txt

real    0m2,843s
user    0m2,788s
sys     0m0,044s

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation generic --number-threads 10
23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,542s
user    0m4,470s
sys     0m0,073s

real    0m0,006s
user    0m0,002s
sys     0m0,004s

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation avx2 --number-threads 10                                               
23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,023s
user    0m0,057s
sys     0m0,086s
[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation avx512 --number-threads 10                                             
23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,028s
user    0m0,081s
sys     0m0,084s

[arthur@emmi wordcount]$ time ./wc tests/plato1g.txt --implementation avx512 --number-threads 10
23220400 195711880 1073979760  tests/plato1g.txt

real    0m0,021s
user    0m0,054s
sys     0m0,077s

Compared to fastlwc:

[arthur@emmi wordcount]$ time ../../fastlwc/bin/fastlwc-mt tests/plato1g.txt
 23220400 195711880 1073979760 tests/plato1g.txt

real    0m0,031s
user    0m0,114s
sys     0m0,219s

[arthur@emmi wordcount]$ time ../../fastlwc/bin/fastlwc-mt tests/plato1g.txt
 23220400 195711880 1073979760 tests/plato1g.txt

real    0m0,022s
user    0m0,151s
sys     0m0,202s

[arthur@emmi wordcount]$ time ../../fastlwc/bin/fastlwc-mt tests/plato1g.txt
 23220400 195711880 1073979760 tests/plato1g.txt

real    0m0,021s
user    0m0,134s
sys     0m0,206s

As said, this is still a WIP so experiments are still ongoing, one day when I am
done I'll write a blog post. Test file I used is 1g big:

[arthur@emmi wordcount]$ tree -hs
[4.0K]  .
....
│   ├── [443M]  plato100.txt
│   ├── [1.0G]  plato1g.txt
│   ├── [3.7M]  plato.org
│   └── [ 12K]  test-avx512-kernels.lisp
....

Made via script in tools/append-file.lisp (run in repl).
