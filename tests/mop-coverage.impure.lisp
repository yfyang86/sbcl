;;;; The MOP coverage battery of the ConsCell port (MOP-Coverage.md)
;;;; as an in-tree test: the one upstream gap it names — ENSURE-CLASS
;;;; with programmatic :DIRECT-SLOTS in the DEFCLASS source syntax —
;;;; plus the generic that gap report asks for
;;;; (SB-MOP:SLOT-EXISTS-P-USING-CLASS) and the specializer parity
;;;; checks of its section 2.6. Everything here is enforced, not
;;;; tolerated. (An impure file: the pure runner's globaldb snapshot
;;;; does not tolerate runtime class definitions.)

(defclass mop-coverage-probe () ((x :initarg :x) (hidden :initarg :hidden)))

(with-test (:name (:mop ensure-class-with-direct-slots)) ; was KNOWN-SBCL-GAP
  ;; the DEFCLASS source syntax, what every programmatic caller coming
  ;; from DEFCLASS writes
  (let ((class (sb-pcl::ensure-class
                'mop-coverage-ensure-class
                :direct-superclasses '(sb-mop:standard-object)
                :direct-slots '((y :initarg :y :initform 7)
                                (z :reader mop-coverage-z :initarg :z)))))
    (assert (eq class (find-class 'mop-coverage-ensure-class)))
    (let ((slots (sb-mop:class-direct-slots class)))
      (assert (= 2 (length slots)))
      (assert (eq 'y (sb-mop:slot-definition-name (first slots))))
      (assert (equal '(:y) (sb-mop:slot-definition-initargs (first slots))))
      (assert (eql 7 (funcall (sb-mop:slot-definition-initfunction (first slots)))))
      (assert (equal '(mop-coverage-z)
                     (sb-mop:slot-definition-readers (second slots)))))
    (assert (eql 7 (slot-value (make-instance 'mop-coverage-ensure-class) 'y)))
    (assert (eql 3 (mop-coverage-z
                    (make-instance 'mop-coverage-ensure-class :z 3)))))
  ;; redefinition through the same path, and a bare slot name
  (sb-pcl::ensure-class 'mop-coverage-ensure-class
                        :direct-superclasses '(sb-mop:standard-object)
                        :direct-slots '(w))
  (assert (slot-exists-p (make-instance 'mop-coverage-ensure-class) 'w))
  ;; the canonicalized plist of the DEFCLASS expansion keeps working
  (sb-pcl::ensure-class 'mop-coverage-ensure-class
                        :direct-superclasses '(sb-mop:standard-object)
                        :direct-slots '((:name y :initargs (:y)
                                         :initform 9
                                         :initfunction constantly-9)))
  (assert (eql 9 (slot-value (make-instance 'mop-coverage-ensure-class) 'y)))
  ;; slot definition metaobjects are used as the direct slots
  (let ((slotd (first (sb-mop:class-direct-slots
                       (find-class 'mop-coverage-ensure-class)))))
    (sb-pcl::ensure-class 'mop-coverage-ensure-class2
                          :direct-superclasses '(sb-mop:standard-object)
                          :direct-slots (list slotd))
    (assert (eq slotd (first (sb-mop:class-direct-slots
                              (find-class 'mop-coverage-ensure-class2))))))
  ;; a bad spec still errors, clearly
  (assert (typep (nth-value 1 (ignore-errors
                               (sb-pcl::ensure-class
                                'mop-coverage-ensure-class
                                :direct-slots '((y :initarg)))))
                 'program-error)))

(with-test (:name (:mop slot-exists-p-using-class))            ; was absent
  ;; the generic exists, is exported, CL:SLOT-EXISTS-P goes through
  ;; it, and it is specializable (Closer-mop's extension point)
  (assert (eq 'sb-mop:slot-exists-p-using-class
              (find-symbol "SLOT-EXISTS-P-USING-CLASS" "SB-MOP")))
  (let ((object (make-instance 'mop-coverage-probe)))
    (assert (slot-exists-p object 'x))
    (assert (not (slot-exists-p object 'nope))))
  (let ((around
          (defmethod sb-mop:slot-exists-p-using-class :around
              ((class sb-mop:standard-class) object slot-name)
            (or (eq slot-name 'nope) (call-next-method)))))
    (assert (slot-exists-p (make-instance 'mop-coverage-probe) 'nope))
    (assert (not (slot-exists-p (make-instance 'mop-coverage-probe) 'absent-slot)))
    (remove-method #'sb-mop:slot-exists-p-using-class around)))

(with-test (:name (:mop specializer parity))                   ; section 2.6
  ;; the specializer protocol on the port: the generic functions
  ;; exist and answer
  (let* ((method (defmethod mop-coverage-gf ((x mop-coverage-probe)) :probe))
         (specl (first (sb-mop:method-specializers method))))
    (assert (eq #'mop-coverage-gf
                (first (sb-mop:specializer-direct-generic-functions specl))))
    (assert (eq method (first (sb-mop:specializer-direct-methods specl))))
    (assert (= 1 (length (sb-mop:compute-applicable-methods-using-classes
                          #'mop-coverage-gf
                          (list (find-class 'mop-coverage-probe))))))
    (remove-method #'mop-coverage-gf method)
    (assert (null (sb-mop:specializer-direct-methods specl)))))

(with-test (:name (:mop exports))                              ; section 2.2
  ;; the CL generics the MOP story re-exports
  (dolist (name '(slot-unbound slot-missing no-applicable-method
                   no-next-method))
    (let ((mop (find-symbol (string name) "SB-MOP"))
          (cl (find-symbol (string name) "COMMON-LISP")))
      (assert (and mop (eq mop cl))))))

;;; undo the definitions: the pure runner snapshots globaldb
(dolist (name '(mop-coverage-ensure-class mop-coverage-ensure-class2))
  (setf (find-class name nil) nil))
(fmakunbound 'mop-coverage-gf)
(fmakunbound 'mop-coverage-z)
(setf (find-class 'mop-coverage-probe) nil)
