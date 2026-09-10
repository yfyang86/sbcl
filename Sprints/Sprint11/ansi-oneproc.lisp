;;; Sprint 11: the whole ANSI suite in one process, see develop.md section 1
;;; every pending test in one process (the state-dependence check), the
;;; INVOKE-DEBUGGER tests left out (they end the process under
;;; --disable-debugger); failures printed as "FAIL name"
(in-package :cl-test)
(let ((n 0) (fails 0) (out *error-output*))
  (dolist (name (rt:pending-tests))
    (incf n)
    (if (search "INVOKE-DEBUGGER" (symbol-name name))
        (format out "~&SKIP ~A~%" name)
        (let ((ok (let ((*standard-output* (make-broadcast-stream)) (*error-output* (make-broadcast-stream)))
                    (rt:do-test name))))
          (unless ok (incf fails) (format out "~&FAIL ~A~%" name))))
    (when (zerop (mod n 500)) (format out "~&;; ~D tests, ~D failures~%" n fails) (finish-output out)))
  (format out "~&;; done: ~D tests, ~D failures~%" n fails))
(sb-ext:exit)
