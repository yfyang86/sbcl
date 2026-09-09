;;;; The ANSI suite on the WebAssembly port: one test at a time, each
;;;; result recorded before the next starts, so that a backend trap (which
;;;; ends the process) costs one test and the run resumes from the next
;;;; (tests/wasm-ansi-tests.sh). Loaded into the core saved with the
;;;; suite; see the shell script for the files.

(in-package :cl-test)

(defun wasm-read-lines (file)
  (with-open-file (in file :if-does-not-exist nil)
    (when in (loop for line = (read-line in nil) while line collect line))))

(defun wasm-record (file line)
  (with-open-file (out file :direction :output :if-exists :append :if-does-not-exist :create)
    (write-line line out)))

(defun wasm-run-tests (results-file progress-file retry-file)
  "Run the pending tests not yet in RESULTS-FILE (lines \"NAME PASS|FAIL|CRASHED\"),
writing each name to PROGRESS-FILE before it runs. A name left in
PROGRESS-FILE by a run that died is retried once (RETRY-FILE remembers
the retry) and then recorded as CRASHED."
  (let ((done (make-hash-table :test 'equal)))
    (dolist (line (wasm-read-lines results-file))
      (setf (gethash (subseq line 0 (position #\Space line)) done) t))
    (let ((pending (first (wasm-read-lines progress-file))))
      (when (and pending (not (equal pending "DONE")) (not (gethash pending done)))
        (if (equal (first (wasm-read-lines retry-file)) pending)
            (progn (wasm-record results-file (format nil "~A CRASHED" pending))
                   (setf (gethash pending done) t))
            (with-open-file (out retry-file :direction :output :if-exists :supersede)
              (write-line pending out)))))
    (let ((count 0))
      (dolist (name (rt:pending-tests))
        (let ((key (prin1-to-string name)))
          (unless (gethash key done)
            (with-open-file (out progress-file :direction :output :if-exists :supersede)
              (write-line key out))
            (let ((ok (rt:do-test name)))
              (wasm-record results-file (format nil "~A ~A" key (if ok "PASS" "FAIL"))))
            (when (zerop (mod (incf count) 500))
              (format t "~&;; ~D tests run in this process~%" count)
              (finish-output))))))
    (with-open-file (out progress-file :direction :output :if-exists :supersede)
      (write-line "DONE" out))
    (sb-ext:exit :code 0)))
