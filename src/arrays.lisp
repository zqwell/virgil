;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-

;;; Copyright (C) 2010-2011, Dmitry Ignatiev <lovesan.ru@gmail.com>

;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:

;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.

(in-package #:virgil)

(define-translatable-type sequence-type ()
  ((element-type :initarg :element-type
                 :initform nil
                 :reader st-elt-type)
   (lisp-type :initarg :lisp-type
              :initform nil
              :reader st-lisp-type))
  (:size (value type)
    (* (compute-fixed-size (st-elt-type type))
       (1+ (length value))))
  (:size-expansion (value-form type)
    `(* ,(compute-fixed-size (st-elt-type type))
        (1+ (length (the ,(lisp-type type)
                         ,value-form)))))
  (:prototype (type)
    (make-sequence (lisp-type type) 0))
  (:prototype-expansion (type)
    `(make-sequence ',(lisp-type type) 0
       :initial-element ,(expand-prototype (st-elt-type type))))
  (:align (type)
    (compute-alignment (st-elt-type type)))
  (:lisp-type (type)
    (or (st-lisp-type type) 'sequence))
  (:allocator-expansion (value type)
    `(raw-alloc ,(expand-compute-size value type)))
  (:deallocator-expansion (pointer type)
    `(raw-free ,pointer)))

(define-translatable-type static-sequence-type (sequence-type)
  ((length :initarg :length 
           :initform 0
           :reader st-length))
  (:fixed-size (type)
    (* (st-length type)
       (compute-fixed-size (st-elt-type type))))
  (:prototype (type)
    (make-sequence (or (st-lisp-type type) 'vector) (st-length type)
      :initial-element (prototype (st-elt-type type))))
  (:prototype-expansion (type)
    `(make-sequence ',(or (st-lisp-type type) 'vector) ,(st-length type)
       :initial-element ,(expand-prototype (st-elt-type type)))))

(define-type-parser sequence (element-type &optional length lisp-type)
  (check-type length (or null non-negative-fixnum))
  (let ((elt-type (parse-typespec element-type)))
    (compute-fixed-size elt-type)
    (if (null length)
      (make-instance 'sequence-type
        :element-type elt-type
        :lisp-type lisp-type)
      (make-instance 'static-sequence-type
        :element-type elt-type
        :lisp-type lisp-type
        :length length))))

(defalias ~ (&rest args) `(sequence ,@args))

(defmethod unparse-type ((type sequence-type))
  `(sequence ,(unparse-type (st-elt-type type))
             nil
             ,@(ensure-list (st-lisp-type type))))

(defmethod unparse-type ((type static-sequence-type))
  `(sequence ,(unparse-type (st-elt-type type))
             ,(st-length type)
             ,@(ensure-list (st-lisp-type type))))

(declaim (inline zero-memory))
(defun zero-memory (pointer size)
  (declare (type pointer pointer)
           (type non-negative-fixnum size))
  (dotimes (i size)
    (setf (mem-ref pointer :uint8 i) 0)))

(declaim (inline zero-memory-p))
(defun zero-memory-p (pointer size)
  (declare (type pointer pointer)
           (type non-negative-fixnum size))
  (loop :for i :below size
    :always (zerop (mem-ref pointer :uint8 i))))

(declaim (inline seqlen))
(defun seqlen (pointer elt-size)
  (declare (type pointer pointer)
           (type non-negative-fixnum elt-size))
  (loop :for i fixnum :from 0
    :until (zero-memory-p (inc-pointer pointer (* i elt-size))
                          elt-size)
    :finally (return i)))

(defmethod read-value (pointer out (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (seqlen pointer elt-size))
         (result (if (null out)
                   (make-sequence (or (st-lisp-type type) 'vector)                  
                     len :initial-element (prototype elt-type))
                   out)))
    (declare (type non-negative-fixnum elt-size len)
             (type sequence result)
             (type pointer pointer))
    (dotimes (i len result)
      (setf (elt result i)
            (read-value (inc-pointer pointer (* i elt-size))
                        (elt result i)
                        elt-type)))))

(defmethod expand-read-value (pointer out (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i result len)
      (once-only (out pointer)
        `(let* ((,len (seqlen ,pointer ,elt-size))
                (,result (if (null ,out)
                           (make-sequence ',(or (st-lisp-type type) 'vector)
                             ,len :initial-element ,(expand-prototype elt-type))
                           ,out)))
           (declare (type non-negative-fixnum ,len)
                    (type ,(lisp-type type) ,result)
                    (type pointer ,pointer))
           (dotimes (,i ,len ,result)
             (setf (elt ,result ,i)
                   ,(expand-read-value
                      `(inc-pointer ,pointer (* ,i ,elt-size))
                      `(elt ,result ,i)
                      elt-type))))))))

(defmethod read-value (pointer out (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (st-length type))
         (result (if (null out)
                   (prototype type)
                   out)))
    (declare (type sequence result)
             (type pointer pointer)
             (type non-negative-fixnum elt-size len))
    (dotimes (i len result)
      (setf (elt result i)
            (read-value (inc-pointer pointer (* i elt-size))
                        (elt result i)
                        elt-type)))))

(defmethod expand-read-value (pointer out (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (* elt-size (st-length type))))
    (once-only (pointer out)
      (with-gensyms (i result)
        `(let ((,result (if (null ,out)
                          ,(expand-prototype type)
                          ,out)))
           (declare (type ,(lisp-type type) ,result)
                    (type pointer ,pointer))
           (dotimes (,i ,len ,result)
             (setf (elt ,result ,i)
                   ,(expand-read-value
                      `(inc-pointer ,pointer (* ,i ,elt-size))
                      `(elt ,result ,i)
                      elt-type))))))))

(defmethod write-value (value pointer (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (length value)))
    (declare (type non-negative-fixnum len elt-size)
             (type sequence value)
             (type pointer pointer))
    (dotimes (i len)
      (write-value (elt value i)
                   (inc-pointer pointer (* i elt-size))
                   elt-type))
    (zero-memory (inc-pointer pointer (* len elt-size)) elt-size)
    pointer))

(defmethod expand-write-value (value pointer (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i len)
      (once-only (value pointer)
        `(let ((,len (length ,value)))
           (declare (type non-negative-fixnum ,len)
                    (type ,(lisp-type type) ,value)
                    (type pointer ,pointer))
           (dotimes (,i ,len)
             ,(expand-write-value
                `(elt ,value ,i)
                `(inc-pointer ,pointer (* ,i ,elt-size))
                elt-type))
           (zero-memory (inc-pointer ,pointer (* ,len ,elt-size)) ,elt-size)
           ,pointer)))))

(defmethod write-value (value pointer (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (st-length type)))
    (declare (type non-negative-fixnum len elt-size)
             (type sequence value)
             (type pointer pointer))
    (dotimes (i len pointer)
      (write-value (elt value i)
                   (inc-pointer pointer (* i elt-size))
                   elt-type))))

(defmethod expand-write-value (value pointer (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (st-length type)))
    (with-gensyms (i)
      (once-only (pointer value)
        `(locally
           (declare (type pointer ,pointer)
                    (type ,(lisp-type type) ,value))
           (dotimes (,i ,len ,pointer)
             ,(expand-write-value
                `(elt ,value ,i)
                `(inc-pointer ,pointer (* ,i ,elt-size))
                elt-type)))))))

(defmethod clean-value (pointer value (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (seqlen pointer elt-size)))
    (declare (type pointer pointer)
             (type non-negative-fixnum len elt-size))
    (dotimes (i len)
      (clean-value (inc-pointer pointer (* i elt-size))
                     (elt value i)
                     elt-type))))

(defmethod expand-clean-value
    (pointer-form value-form (type sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i len pointer value)
      `(let ((,pointer ,pointer-form)
             (,value ,value-form))
         (declare (type ,(lisp-type type) ,value)
                  (type pointer ,pointer)
                  (ignorable ,pointer ,value))
         (let ((,len (seqlen ,pointer ,elt-size)))
           (declare (type non-negative-fixnum ,len))
           (%dotimes (,i ,len)
             ,(expand-clean-value
                `(inc-pointer ,pointer (* ,i ,elt-size))
                `(elt ,value ,i)
                elt-type)))))))

(defmethod clean-value (pointer value (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (st-length type)))
    (declare (type pointer pointer)
             (type sequence value)
             (type non-negative-fixnum len elt-size))
    (dotimes (i len)
      (clean-value (inc-pointer pointer (* i elt-size))
                     (elt value i)
                     elt-type))))

(defmethod expand-clean-value
    (pointer-form value-form (type static-sequence-type))
  (let* ((elt-type (st-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (len (st-length type)))
    (with-gensyms (i pointer value)
      `(let ((,pointer ,pointer-form)
             (,value ,value-form))
         (declare (type pointer ,pointer)
                  (type ,(lisp-type type) ,value)
                  (ignorable ,pointer ,value))
         (%dotimes (,i ,len)
           ,(expand-clean-value
              `(inc-pointer ,pointer (* ,i ,elt-size))
              `(elt ,value ,i)
              elt-type))))))

(define-translatable-type array-type ()
  ((element-type :initform nil :initarg :element-type
                 :reader at-elt-type))
  (:size (value type)
    (* (compute-fixed-size (at-elt-type type))
       (array-total-size value)))
  (:size-expansion (value type)
    `(* ,(compute-fixed-size (at-elt-type type))
        (array-total-size (the ,(lisp-type type)
                               ,value))))
  (:lisp-type (type)
    `(array ,(lisp-type (at-elt-type type))))
  (:prototype (type)
    (make-array '() :element-type (lisp-type (at-elt-type type))))
  (:prototype-expansion (type)
    `(make-array '() :element-type ',(lisp-type (at-elt-type type))
       :initial-element ,(expand-prototype (at-elt-type type))))
  (:align (type) (compute-alignment (at-elt-type type)))
  (:allocator-expansion (value type)
    `(raw-alloc ,(expand-compute-size value type)))
  (:deallocator (pointer type)
    `(raw-free ,pointer)))

(define-translatable-type static-array-type (array-type)
  ((dimensions :initarg :dimensions :initform '()
               :reader at-dims))
  (:fixed-size (type)
    (* (compute-fixed-size (at-elt-type type))
       (reduce #'* (at-dims type))))
  (:lisp-type (type)
    `(array ,(lisp-type (at-elt-type type))
            ,(at-dims type)))
  (:prototype (type)
    (make-array (at-dims type)
      :element-type (lisp-type (at-elt-type type))
      :initial-element (prototype (at-elt-type type))))
  (:prototype-expansion (type)
    `(make-array ',(at-dims type)
       :element-type ',(lisp-type (at-elt-type type))
       :initial-element ,(expand-prototype (at-elt-type type)))))

(define-translatable-type simple-array-type (array-type)
  ()
  (:lisp-type (type)
    `(simple-array ,(lisp-type (at-elt-type type)))))

(define-translatable-type static-simple-array-type
    (simple-array-type static-array-type)
  ()
  (:lisp-type (type)
    `(simple-array ,(lisp-type (at-elt-type type))
                   ,(at-dims type))))

(define-type-parser array (element-type &optional (dimensions '*))
  (assert (or (eq '* dimensions)
              (and (listp dimensions)
                   (every (lambda (x)
                            (typep x 'non-negative-fixnum))
                          dimensions)))
      (dimensions))
  (let ((elt-type (parse-typespec element-type)))
    (compute-fixed-size elt-type)
    (if (eq '* dimensions)
      (make-instance 'array-type
        :element-type elt-type)
      (make-instance 'static-array-type
        :element-type elt-type
        :dimensions dimensions))))

(defmethod unparse-type ((type array-type))
  `(array ,(unparse-type (at-elt-type type))))

(defmethod unparse-type ((type static-array-type))
  `(array ,(unparse-type (at-elt-type type))
          ,(at-dims type)))

(define-type-parser simple-array (element-type &optional (dimensions '*))
  (assert (or (eq '* dimensions)
              (and (listp dimensions)
                   (every (lambda (x)
                            (typep x 'non-negative-fixnum))
                          dimensions)))
      (dimensions))
  (let ((elt-type (parse-typespec element-type)))
    (compute-fixed-size elt-type)
    (if (eq '* dimensions)
      (make-instance 'simple-array-type
        :element-type elt-type)
      (make-instance 'static-simple-array-type
        :element-type elt-type
        :dimensions dimensions))))

(defmethod unparse-type ((type simple-array-type))
  `(simple-array ,(unparse-type (at-elt-type type))))

(defmethod unparse-type ((type static-simple-array-type))
  `(simple-array ,(unparse-type (at-elt-type type))
                 ,(at-dims type)))

(defun error-no-output-supplied (type)
  (error "Type ~s needs output to be supplied in read operations"
         type))

(defmethod read-value (pointer out (type array-type))
  (let* ((total-size (if (null out)
                       (error-no-output-supplied type)
                       (array-total-size out)))
         (elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (declare (type non-negative-fixnum total-size elt-size))
    (dotimes (i total-size out)
      (setf (row-major-aref out i)
            (read-value (inc-pointer pointer (* i elt-size))
                        (row-major-aref out i)
                        elt-type)))))

(defmethod expand-read-value (pointer out (type array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (total-size i result)
      (once-only (pointer out)
        `(locally
           (declare (type pointer ,pointer))
           (let* ((,total-size (if (null ,out)
                                 (error-no-output-supplied ,type)
                                 (array-total-size ,out)))
                  (,result ,out))
             (declare (type non-negative-fixnum ,total-size)
                      (type ,(lisp-type type) ,result))
             (dotimes (,i ,total-size ,result)
               (setf (row-major-aref ,result ,i)
                     ,(expand-read-value
                        `(inc-pointer ,pointer (* ,i ,elt-size))
                        `(row-major-aref ,result ,i)
                        elt-type)))))))))

(defmethod read-value (pointer out (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (result (if (null out)
                   (prototype type)
                   out))
         (total-size (reduce #'* (at-dims type))))
    (declare (type array result)
             (type non-negative-fixnum total-size elt-size))
    (dotimes (i total-size result)
      (setf (row-major-aref result i)
            (read-value (inc-pointer pointer (* i elt-size))
                        (row-major-aref result i)
                        elt-type)))))

(defmethod expand-read-value (pointer out (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (total-size (reduce #'* (at-dims type))))
    (once-only (pointer out)
      (with-gensyms (i result)
        `(let ((,result (if (null ,out)
                          ,(expand-prototype type)
                          ,out)))
           (declare (type ,(lisp-type type) ,result)
                    (type pointer ,pointer))
           (dotimes (,i ,total-size ,result)
             (setf (row-major-aref ,result ,i)
                   ,(expand-read-value
                      `(inc-pointer ,pointer (* ,i ,elt-size))
                      `(row-major-aref ,result ,i)
                      elt-type))))))))

(defmethod write-value (value pointer (type array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (declare (type pointer pointer)
             (type array value)
             (type non-negative-fixnum elt-size))
    (dotimes (i (array-total-size value) pointer)
      (write-value (row-major-aref value i)
                   (inc-pointer pointer (* i elt-size))
                   elt-type))))

(defmethod expand-write-value (value pointer (type array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i)
      (once-only (value pointer)
        `(locally
           (declare (type ,(lisp-type type) ,value)
                    (type pointer ,pointer))
           (dotimes (,i (array-total-size ,value) ,pointer)
             ,(expand-write-value
                `(row-major-aref ,value ,i)
                `(inc-pointer ,pointer (* ,i ,elt-size))
                elt-type)))))))

(defmethod write-value (value pointer (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (declare (type pointer pointer)
             (type array value)
             (type non-negative-fixnum elt-size))
    (dotimes (i (reduce #'* (at-dims type)) pointer)
      (write-value (row-major-aref value i)
                   (inc-pointer pointer (* i elt-size))
                   elt-type))))

(defmethod expand-write-value (value pointer (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i)
      (once-only (value pointer)
        `(locally
           (declare (type pointer ,pointer)
                    (type ,(lisp-type type) ,value))
           (dotimes (,i ,(reduce #'* (at-dims type)) ,pointer)
             ,(expand-write-value
                `(row-major-aref ,value ,i)
                `(inc-pointer ,pointer (* ,i ,elt-size))
                elt-type)))))))

(defmethod clean-value (pointer value (type array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (total-size (array-total-size value)))
    (declare (type pointer pointer)
             (type non-negative-fixnum elt-size total-size))
    (dotimes (i total-size)
      (clean-value (inc-pointer pointer (* i elt-size))
                     (row-major-aref value i)
                     elt-type))))

(defmethod expand-clean-value
    (pointer-form value-form (type array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type)))
    (with-gensyms (i total-size pointer value)
      `(let ((,pointer ,pointer-form)
             (,value ,value-form))
         (declare (type ,(lisp-type type) ,value)
                  (type pointer ,pointer)
                  (ignorable ,pointer ,value))
         (let ((,total-size (array-total-size ,value)))
           (declare (type non-negative-fixnum ,total-size))
           (%dotimes (,i ,total-size)
             ,(expand-clean-value
                `(inc-pointer ,pointer (* ,i ,elt-size))
                `(row-major-aref ,value ,i)
                elt-type)))))))

(defmethod clean-value (pointer value (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (total-size (reduce #'* (at-dims type))))
    (declare (type non-negative-fixnum total-size elt-size)
             (type pointer pointer)
             (type array value))
    (dotimes (i total-size)
      (clean-value (inc-pointer pointer (* i elt-size))
                     (row-major-aref value i)
                     elt-type))))

(defmethod expand-clean-value
    (pointer-form value-form (type static-array-type))
  (let* ((elt-type (at-elt-type type))
         (elt-size (compute-fixed-size elt-type))
         (total-size (reduce #'* (at-dims type))))
    (with-gensyms (i pointer value)
      `(let ((,pointer ,pointer-form)
             (,value ,value-form))
         (declare (type ,(lisp-type type) ,value)
                  (type pointer ,pointer)
                  (ignorable ,pointer ,value))
         (%dotimes (,i ,total-size)
           ,(expand-clean-value
              `(inc-pointer ,pointer (* ,i ,elt-size))
              `(row-major-aref ,value ,i)
              elt-type))))))

(defun pinned-vector-elt-type-p (type)
  (or (and (primitive-type-p type)
           (member (primitive-type-cffi-type type)
                   '(#+(or sbcl cmu ecl openmcl lispworks allegro cormanlisp)
                     (:float :double)
                     #+(or sbcl cmu ecl allegro lispworks openmcl cormanlisp)
                     (:char :unsigned-char :uchar :int8 :uint8
                            :short :unsigned-short :ushort :int16 :uint16)
                     #+(or sbcl cmu allegro lispworks openmcl)
                     (:int :uint :int32 :uint32 :unsigned-int)
                     #+(and x86-64 (or sbcl cmu allegro lispworks))
                     (:llong :ullong :long-long :unsigned-long-long
                      :int64 :uint64))
                   :test #'member))
      (and (typep type 'char-type)
           #+(or sbcl) T
           #-(or sbcl) nil)))

(defmethod expand-reference-dynamic-extent
    (var size-var value-var body mode (type static-sequence-type))
  (check-type mode (member :in :out :inout))
  (let ((elt-type (st-elt-type type)))
    (if (or (eq mode :in)
            (not (pinned-vector-elt-type-p elt-type)))
      (call-next-method)
      (let ((elt-size (compute-fixed-size elt-type)))
        (with-gensyms (vector start end value)
          `(let ((,value ,value-var))
             (declare (type ,(lisp-type type) ,value))
             (with-simple-vector ((,vector ,value) (,start 0) (,end #+sbcl nil #-sbcl (array-total-size ,value)))
               (declare (ignore ,start ,end))
               (with-pointer-to-vector-data (,var ,vector)
                 (let ((,size-var ,(* elt-size (st-length type))))
                   (declare (ignorable ,size-var)
                            (type pointer ,var))
                   (prog1 (progn ,@body)
                    (setf ,value-var ,value)))))))))))

(defmethod expand-reference-dynamic-extent
    (var size-var value-var body mode (type array-type))
  (check-type mode (member :in :out :inout))
  (let ((elt-type (at-elt-type type)))
    (if (or (eq mode :in)
            (not (pinned-vector-elt-type-p elt-type)))
      (call-next-method)
      (let ((elt-size (compute-fixed-size elt-type)))
        (with-gensyms (vector start end value)
          `(let ((,value ,value-var))
             (declare (type ,(lisp-type type) ,value))
             (with-simple-vector ((,vector ,value) (,start 0) (,end #+sbcl nil #-sbcl (array-total-size ,value)))
               (declare (ignore ,start)
                        (type non-negative-fixnum ,end)
                        (ignorable ,end))
               (with-pointer-to-vector-data (,var ,vector)
                 (let ((,size-var ,(if (typep type 'static-array-type)
                                     (* elt-size (reduce #'* (at-dims type)))
                                     `(* ,elt-size ,end))))
                   (declare (ignorable ,size-var)
                            (type pointer ,var))
                   (prog1 (progn ,@body)
                    (setf ,value-var ,value)))))))))))
