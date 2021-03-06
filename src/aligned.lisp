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
;;; DEALINGS IN THE SOFTWARE

(in-package #:virgil)

(defun align-exp2-p (align)
  (zerop (logand align (1- align))))

(define-proxy-type aligned-type ()
  ((align :initform 1
          :initarg :align
          :accessor aligned-type-align))
  (:align (type)
    (aligned-type-align type))
  (:allocator (value type)
    (let* ((size (compute-size value (proxied-type type)))
           (align (aligned-type-align type))
           (padding (+ (sizeof '*) (1- align)))
           (pointer (raw-alloc (+ padding size)))
           (aligned-pointer (if (align-exp2-p align)
                              (logand (&& (&+ pointer (+ (sizeof '*) (1- align))))
                                      (lognot (1- align)))
                              (& (align-offset
                                   (&& (&+ pointer (sizeof '*)))
                                   align)))))
      (setf (deref aligned-pointer '* (- (sizeof '*)))
            pointer)
      aligned-pointer))
  (:allocator-expansion (value-form type)
    (with-gensyms (value size pointer aligned-pointer)
      (let* ((atype (proxied-type type))
             (align (aligned-type-align type))
             (padding (+ (sizeof '*) (1- align))))
        `(let* ((,value (the ,(lisp-type atype) ,value-form))
                (,size (the size-t ,(expand-compute-size value atype)))
                (,pointer (raw-alloc (+ ,padding ,size)))
                (,aligned-pointer ,(if (align-exp2-p align)
                                     `(& (logand
                                           (the size-t (&& (&+ ,pointer ,(+ (sizeof '*)
                                                                            (1- align)))))
                                           ,(lognot (1- align))))
                                     `(& (align-offset
                                           (&& (&+ ,pointer ,(sizeof '*)))
                                           ,align)))))
           (declare (ignorable ,value)
                    (type pointer ,pointer ,aligned-pointer))
           (setf (deref ,aligned-pointer '* (- ,(sizeof '*)))
                 ,pointer)
           ,aligned-pointer))))
  (:deallocator (pointer type)
    (raw-free (deref pointer '* (- (sizeof '*)))))
  (:deallocator-expansion (pointer-form type)
    `(raw-free (deref ,pointer-form '* (- ,(sizeof '*)))))
  (:reference-dynamic-extent-expansion (var size-var value-var body mode type)
    (let* ((atype (proxied-type type))
           (align (aligned-type-align type)))
      (with-gensyms (pointer-var)
        `(with-raw-pointer (,pointer-var
                             ,(eval-if-constantp
                                `(+ ,(1- align)
                                    ,(expand-compute-size
                                       value-var
                                       atype)))
                             ,size-var)
           (let* ((,pointer-var ,(if (align-exp2-p align)
                                     `(& (logand
                                           (the size-t (&& (&+ ,pointer-var ,(1- align))))
                                           ,(lognot (1- align))))
                                     `(& (align-offset
                                           (&& ,pointer-var)
                                           ,align))))
                  (,var ,pointer-var))
             (declare (type pointer ,pointer-var ,var)
                      (type ,(lisp-type atype) ,value-var))
             (%unwind-protect
               ,(ecase mode
                  (:in `(progn ,(expand-write-value value-var pointer-var atype)
                               nil
                               ,@body))
                  (:out `(prog1 (progn ,@body)
                          (setf ,value-var
                                ,(expand-read-value pointer-var value-var atype))))
                  (:inout `(prog1 (progn
                                    ,(expand-write-value value-var pointer-var atype)
                                    nil
                                    ,@body)
                            (setf ,value-var
                                  ,(expand-read-value pointer-var value-var atype)))))
               ,(expand-clean-value pointer-var value-var atype))))))))

(define-immediate-type aligned-immediate-type (aligned-type)
  ())

(define-type-parser aligned (align aligned-type)
  (check-type align non-negative-fixnum)
  (let ((type (parse-typespec aligned-type)))
    (make-instance (if (immediate-type-p type)
                     'aligned-immediate-type
                     'aligned-type)
      :type type
      :align align)))

(defmethod unparse-type ((type aligned-type))
  `(aligned ,(aligned-type-align type)
            ,(unparse-type (proxied-type type))))
