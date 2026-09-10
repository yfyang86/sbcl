;;;; This is an automatically generated file, please do not hand-edit it.
;;;; See the program "grovel-headers.c".

(in-package "SB-ALIEN")

;;;flags for dlopen()
(defconstant rtld-lazy 1) ; #x1
(defconstant rtld-now 2) ; #x2
(defconstant rtld-global 256) ; #x100

(in-package "SB-UNIX")

;;; select()
(defconstant fd-setsize 1024) ; #x400
;;; poll()
(defconstant pollin 1) ; #x1
(defconstant pollout 2) ; #x2
(defconstant pollpri 512) ; #x200
(defconstant pollhup 8192) ; #x2000
(defconstant pollnval 16384) ; #x4000
(defconstant pollerr 4096) ; #x1000
(define-alien-type nfds-t (unsigned 32))
;;; types, types, types
(define-alien-type clock-t (signed 64))
(define-alien-type dev-t (unsigned 64))
(define-alien-type gid-t (unsigned 32))
(define-alien-type ino-t (unsigned 64))
(define-alien-type mode-t (unsigned 32))
(define-alien-type nlink-t (unsigned 64))
(define-alien-type off-t (signed 64))
(define-alien-type size-t (unsigned 32))
(define-alien-type ssize-t (signed 32))
(define-alien-type time-t (signed 64))
(define-alien-type suseconds-t (signed 32))
(define-alien-type uid-t (unsigned 32))
;; Types in src/runtime/wrap.h. See that file for explantion.
;; Don't use these types for anything other than the stat wrapper.
(define-alien-type wst-ino-t (unsigned 64))
(define-alien-type wst-dev-t (unsigned 64))
(define-alien-type wst-off-t (signed 64))
(define-alien-type wst-blksize-t (unsigned 32))
(define-alien-type wst-blkcnt-t (unsigned 32))
(define-alien-type wst-nlink-t (unsigned 64))
(define-alien-type wst-uid-t (unsigned 32))
(define-alien-type wst-gid-t (unsigned 32))

;;; fcntl.h (or unistd.h on OpenBSD and NetBSD)
(defconstant r_ok 4) ; #x4
(defconstant w_ok 2) ; #x2
(defconstant x_ok 1) ; #x1
(defconstant f_ok 0) ; #x0

;;; fcntlbits.h
(defconstant o_rdonly 67108864) ; #x4000000
(defconstant o_wronly 268435456) ; #x10000000
(defconstant o_rdwr 335544320) ; #x14000000
(defconstant o_accmode 503316480) ; #x1e000000
(defconstant o_creat 4096) ; #x1000
(defconstant o_excl 16384) ; #x4000
(defconstant o_noctty 0) ; #x0
(defconstant o_trunc 32768) ; #x8000
(defconstant o_append 1) ; #x1
;;;
(defconstant s-ifmt 61440) ; #xf000
(defconstant s-ififo 4096) ; #x1000
(defconstant s-ifchr 8192) ; #x2000
(defconstant s-ifdir 16384) ; #x4000
(defconstant s-ifblk 24576) ; #x6000
(defconstant s-ifreg 32768) ; #x8000

(defconstant s-iflnk 40960) ; #xa000
(defconstant s-ifsock 49152) ; #xc000

;;; error numbers
(defconstant ebadf 8) ; #x8
(defconstant enoent 44) ; #x2c
(defconstant eintr 27) ; #x1b
(defconstant eagain 6) ; #x6
(defconstant eio 29) ; #x1d
(defconstant eexist 20) ; #x14
(defconstant eloop 32) ; #x20
(defconstant epipe 64) ; #x40
(defconstant ewouldblock 6) ; #x6

(defconstant sc-nprocessors-onln 84) ; #x54
;;; for waitpid() in run-program.lisp
(defconstant wcontinued 0) ; #x0
(defconstant wnohang 1) ; #x1
(defconstant wuntraced 2) ; #x2

;;; various ioctl(2) flags
(defconstant tiocgpgrp 0) ; #x0

;;; signals
(defconstant sizeof-sigset_t 1) ; #x1
(defconstant sig_block 0) ; #x0
(defconstant sig_unblock 1) ; #x1
(defconstant sig_setmask 2) ; #x2
(defconstant sigalrm 14) ; #xe
(defconstant sigbus 7) ; #x7
(defconstant sigchld 17) ; #x11
(defconstant sigcont 18) ; #x12
(defconstant sigfpe 8) ; #x8
(defconstant sighup 1) ; #x1
(defconstant sigill 4) ; #x4
(defconstant sigint 2) ; #x2
(defconstant sigio 29) ; #x1d
(defconstant sigkill 9) ; #x9
(defconstant sigpipe 13) ; #xd
(defconstant sigprof 27) ; #x1b
(defconstant sigquit 3) ; #x3
(defconstant sigsegv 11) ; #xb
(defconstant sigstkflt 16) ; #x10
(defconstant sigstop 19) ; #x13
(defconstant sigsys 31) ; #x1f
(defconstant sigterm 15) ; #xf
(defconstant sigtrap 5) ; #x5
(defconstant sigtstp 20) ; #x14
(defconstant sigttin 21) ; #x15
(defconstant sigttou 22) ; #x16
(defconstant sigurg 23) ; #x17
(defconstant sigusr1 10) ; #xa
(defconstant sigusr2 12) ; #xc
(defconstant sigvtalrm 26) ; #x1a
(defconstant sigwinch 28) ; #x1c
(defconstant sigxcpu 24) ; #x18
(defconstant sigxfsz 25) ; #x19
(defconstant itimer-real 0) ; #x0
(defconstant itimer-virtual 1) ; #x1
(defconstant itimer-prof 2) ; #x2
(defconstant fpe-intovf 4294967295) ; #xffffffff
(defconstant fpe-intdiv 4294967295) ; #xffffffff
(defconstant fpe-fltdiv 4294967295) ; #xffffffff
(defconstant fpe-fltovf 4294967295) ; #xffffffff
(defconstant fpe-fltund 4294967295) ; #xffffffff
(defconstant fpe-fltres 4294967295) ; #xffffffff
(defconstant fpe-fltinv 4294967295) ; #xffffffff
(defconstant fpe-fltsub 4294967295) ; #xffffffff

(defconstant clock-realtime 0) ; #x0
(defconstant clock-monotonic 1) ; #x1
(defconstant clock-process-cputime-id 2) ; #x2
(defconstant clock-realtime-coarse 5) ; #x5
(defconstant clock-monotonic-coarse 6) ; #x6
(defconstant clock-monotonic-raw 4) ; #x4
(defconstant clock-thread-cputime-id 3) ; #x3
;;; structures
(define-alien-type nil
  (struct timeval
          (tv-sec (signed 64))
          (tv-usec (signed 64))))
(define-alien-type nil
  (struct timespec
          (tv-sec (signed 64))
          (tv-nsec (signed 32))))
(defconstant sizeof-timespec 16) ; #x10
(defconstant sizeof-timeval 16) ; #x10

(defconstant sizeof-unw-cursor 0) ; #x0
(in-package "SB-KERNEL")

;;; GENCGC related
(define-alien-type page-index-t (signed 32))
(define-alien-type generation-index-t (signed 8))

;;; Our runtime types
(define-alien-type os-vm-size-t (unsigned 32))
