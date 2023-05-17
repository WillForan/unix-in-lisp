(uiop:define-package #:unix-in-lisp
  (:use :cl :iter)
  (:import-from :metabang-bind #:bind)
  (:import-from :serapeum #:lastcar :package-exports #:-> #:mapconcat
                #:concat #:string-prefix-p)
  (:import-from :alexandria #:when-let #:if-let #:deletef #:ignore-some-conditions
                #:assoc-value)
  (:export #:cd #:install #:uninstall #:setup #:ensure-path #:contents #:defile #:pipe
           #:repl-connect #:*jobs* #:ensure-env-var #:synchronize-env-to-unix))

(in-package #:unix-in-lisp)

(defvar *post-command-hook* (make-instance 'nhooks:hook-void))

;;; File system

;;;; package system mounting

(-> canonical-symbol (symbol) symbol)
(-> mount-file (t) symbol)
(-> ensure-path (t) string)
(-> mount-directory (t) package)
(-> ensure-homed-symbol (string package) symbol)

(defun convert-case (string)
  "Convert external representation of STRING into internal representation
for `package-name's and `symbol-name's."
  (let ((*print-case* :upcase))
    (format nil "~a" (make-symbol string))))
(defun unconvert-case (string)
  "Convert internal representation STRING from `package-name's and
`symbol-name's into external representations for paths."
  (let ((*print-case* :downcase))
    (format nil "~a" (make-symbol string))))

(defun ensure-executable (symbol)
  (let ((filename (symbol-path symbol)))
    (if (handler-case
            (intersection (osicat:file-permissions filename)
                          '(:user-exec :group-exec :other-exec))
          (osicat-posix:enoent ()
            ;; This warning is too noisy
            #+nil (warn "Probably broken symlink: ~a" filename)
            nil))
        (setf (macro-function symbol) #'command-macro)
        (fmakunbound symbol)))
  symbol)

(defun package-path (package)
  "Returns the namestring of the directory mounted to PACKAGE,
or NIL if PACKAGE is not a UNIX FS package."
  (let ((filename (unconvert-case (package-name package))))
    (when (ppath:isabs filename) filename)))

(defun symbol-path (symbol)
  "Returns the namestring of the file mounted to SYMBOL,
Signals an error if the home package SYMBOL is not a Unix FS package.

Note that SYMBOL must be the canonical mounted symbol, to retrieve the
path designated by any symbol, consider using `ensure-path'."
  (if-let (dir (package-path (symbol-package symbol)))
    (ppath:join dir (unconvert-case (symbol-name symbol)))
    (error "Home package ~S of ~S is not a Unix FS package."
           (symbol-package symbol) symbol)))

(defun canonical-symbol (symbol)
  "Returns the symbol mounted to the path designated by SYMBOL.
This mounts the symbol in the process and may also mount required Unix
FS packages."
  (if-let (path (ignore-errors (ensure-path symbol)))
    (mount-file path)
    symbol))

(defun symbol-home-p (symbol) (eq *package* (symbol-package symbol)))

(defun ensure-path (path)
  "Return the path (a string) designated by PATH.
The result is guaranteed to be a file path (without trailing slashes)."
  (cond ((pathnamep path)
         (setq path (uiop:native-namestring path)))
        ((symbolp path)
         (setq path
               (cond ((or (ppath:isabs (symbol-name path))
                          (string-prefix-p "~" (symbol-name path)))
                      (unconvert-case (symbol-name path)))
                     ((package-path (symbol-package path))
                      (ppath:join (package-path (symbol-package path))
                                  (unconvert-case (symbol-name path))))
                     (t (unconvert-case (symbol-name path)))))))
  (let ((path (ppath:expanduser (ppath:normpath path))))
    (unless (ppath:isabs path)
      (error "~S is not an absolute path." path))
    path))

(defun to-dir (filename) (ppath:join filename ""))

(define-condition wrong-file-kind (simple-error file-error)
  ((wanted-kind :initarg :wanted-kind) (actual-kind :initarg :actual-kind))
  (:report
   (lambda (c s)
     (with-slots (wanted-kind actual-kind) c
       (format s "~a is a ~a, wanted ~a."
               (file-error-pathname c) actual-kind wanted-kind)))))

(define-condition file-does-not-exist (simple-error file-error) ()
  (:report
   (lambda (c s)
     (format s "~a does not exist." (file-error-pathname c)))))

(defun assert-file-kind (path &rest kinds)
  (let ((kind (osicat:file-kind path :follow-symlinks t)))
    (unless (member kind kinds)
      (if kind
          (error 'wrong-file-kind :pathname path :wanted-kind kinds :actual-kind kind)
          (error 'file-does-not-exist :pathname path)))))

(defun mount-directory (path)
  "Mount PATH as a Unix FS package, which must be a directory.
Return the mounted package."
  (setq path (ensure-path path))
  (restart-case
      (assert-file-kind path :directory)
    (create-directory ()
      :test (lambda (c) (typep c 'file-does-not-exist))
      (ensure-directories-exist (to-dir path))))
  (bind ((package-name (convert-case path))
         (package (or (find-package package-name)
                      (uiop:ensure-package package-name :use '("UNIX-IN-LISP.COMMON")))))
    ;; In case the directory is already mounted, check and remove
    ;; symbols whose mounted file no longer exists
    (mapc (lambda (symbol)
            (when (not (ppath:lexists (symbol-path symbol)))
              (unintern symbol package)))
          (package-exports package))
    (mapc #'mount-file (uiop:directory*
                        (merge-pathnames uiop:*wild-file-for-directory* (to-dir path))))
    package))

(defun ensure-homed-symbol (symbol-name package)
  "Make a symbol with PACKAGE as home package.
Return the symbol."
  (let ((symbol (find-symbol symbol-name package)))
    (cond ((not symbol) (intern symbol-name package))
          ((eq (symbol-package symbol) package) symbol)
          (t (let ((use-list (package-use-list package)))
               (unwind-protect
                    (progn
                      (mapc (lambda (p) (unuse-package p package)) use-list)
                      (unintern symbol package)
                      (shadow (list symbol-name) package)
                      (intern symbol-name package))
                 (mapc (lambda (p) (use-package p package)) use-list)))))))

(defun mount-file (filename)
  "Mount FILENAME as a symbol in the appropriate Unix FS package."
  (setq filename (ensure-path filename))
  (unless (ppath:lexists filename)
    (error 'file-does-not-exist :pathname filename))
  (bind (((directory . file) (ppath:split filename))
         (package (or (find-package (convert-case directory)) (mount-directory directory)))
         (symbol (ensure-homed-symbol (convert-case file) package)))
    (setq symbol (ensure-symbol-macro symbol `(access-file (symbol-path ',symbol))))
    (export symbol (symbol-package symbol))
    (when (uiop:file-exists-p filename)
      (ensure-executable symbol))
    symbol))

;; TODO: something more clever, maybe `fswatch'
(defun remount-current-directory ()
  (when-let (pathname (package-path *package*))
    (mount-directory pathname)))

(nhooks:add-hook *post-command-hook* 'remount-current-directory)

;;;; Structured file abstraction

(defun access-file (path)
  (if (uiop:directory-exists-p path)
      (mount-directory path)
      (uiop:read-file-lines path)))

(defun (setf access-file) (new-value path)
  (let ((kind (osicat:file-kind path :follow-symlinks t)))
    (when (eq kind :directory)
        (error 'wrong-file-kind :pathname path :kinds "not directory" :actual-kind kind)))
  (with-open-file
      (stream path :direction :output
                   :if-exists :supersede
                   :if-does-not-exist :create)
    (let ((*standard-output* stream))
      (mapc #'write-line new-value))))

(defmacro file (symbol)
  `(access-file (ensure-path ',symbol)))

(defun reintern-symbol (symbol)
  "Unintern SYMBOL, and intern a symbol with the same name and home
package as SYMBOL.  This is useful for \"clearing\" any bindings.
Code should then use the returned symbol in place of SYMBOL."
  (let ((package (symbol-package symbol)))
    (unintern symbol package)
    (intern (symbol-name symbol) package)))

(defun ensure-symbol-macro (symbol form)
  (let ((binding-type (sb-cltl2:variable-information symbol)))
    (cond ((or (not binding-type) (eq binding-type :symbol-macro))
           (eval `(define-symbol-macro ,symbol ,form)))
          (t (restart-case
                 (error "Symbol ~S already has a ~A binding." symbol binding-type)
               (reckless-continue () :report "Unintern the symbol and retry."
                 (ensure-symbol-macro (reintern-symbol symbol) form)))))))

(defmacro defile (symbol &optional initform)
  (setq symbol (canonical-symbol symbol))
  (setq symbol (ensure-symbol-macro symbol `(access-file (symbol-path ',symbol))))
  `(progn
     ,(when initform `(setf ,symbol ,initform))
     ',symbol))

;;; FD watcher

(defvar *fd-watcher-thread* nil)
(defvar *fd-watcher-event-base* nil)

(defun fd-watcher ()
  (loop (iolib:event-dispatch *fd-watcher-event-base*)))

(defun ensure-fd-watcher ()
  "Setup `*fd-watcher-thread*' and `*fd-watcher-event-base*'.
We mainly use them to interactively copy data between file descriptors
and Lisp streams. We don't use the implementation provided mechanisms
because they often have unsatisfying interactivity (e.g. as of SBCL
2.3.4, for quite a few cases the data is not transferred until the
entire input is seen, i.e. until EOF)."
  (unless (and *fd-watcher-event-base*
               (iolib/multiplex::fds-of *fd-watcher-event-base*))
    (setf *fd-watcher-event-base* (make-instance 'iolib:event-base)))
  (unless (and *fd-watcher-thread*
               (bt:thread-alive-p *fd-watcher-thread*))
    (setf *fd-watcher-thread* (bt:make-thread #'fd-watcher :name "Unix in Lisp FD watcher"))))

(defun cleanup-fd-watcher ()
  "Remove and close all file descriptors from `*fd-watcher-event-base*'.
This is mainly for debugger purpose, to clean up the mess when dubious
file descriptors are left open."
  (iter (for (fd _) in-hashtable (iolib/multiplex::fds-of *fd-watcher-event-base*))
    (iolib:remove-fd-handlers *fd-watcher-event-base* fd)
    (isys:close fd)))

(defun stop-fd-watcher ()
  "Destroy `*fd-watcher-thread*' and `*fd-watcher-event-base*'.
This is unsafe, for debug purpose only."
  (cleanup-fd-watcher)
  (bt:destroy-thread *fd-watcher-thread*)
  (close *fd-watcher-event-base*))

(defun copy-fd-to-stream (read-fd-or-stream stream &optional (continuation (lambda ())))
  "Copy characters from READ-FD-OR-STREAM to STREAM.
Characters are copied and FORCE-OUTPUT as soon as possible, making it
more suitable for interactive usage than some implementation provided
mechanisms."
  (declare (type function continuation))
  (bind (((:values read-fd read-stream)
          (if (streamp read-fd-or-stream)
              (values (sb-sys:fd-stream-fd read-fd-or-stream) read-fd-or-stream)
              (values read-fd-or-stream (sb-sys:make-fd-stream read-fd-or-stream :input t))))
         ((:labels clean-up ())
          (iolib:remove-fd-handlers *fd-watcher-event-base* read-fd)
          (close read-stream)
          (funcall continuation))
         (connection swank-api:*emacs-connection*)
         ((:labels read-data ())
          (swank-api:with-connection (connection)
            (handler-case
                (iter (for c = (read-char-no-hang read-stream))
                  (while c)
                  (write-char c stream)
                  (finally (force-output stream)))
              (end-of-file () (clean-up))
              (error (c) (describe c) (clean-up))))))
    (setf (isys:fd-nonblock-p read-fd) t)
    (ensure-fd-watcher)
    (iolib:set-io-handler
     *fd-watcher-event-base* read-fd
     :read
     (lambda (fd event error)
       (unless (eq event :read)
         (warn "FD watcher ~A get ~A ~A" fd event error))
       (read-data)))
    (values)))

;;; Job control

(defvar *jobs* nil)

;;; Effective Process

;;;; Abstract interactive process
(defclass process-mixin (native-lazy-seq:lazy-seq)
  ((status-change-hook
    :reader status-change-hook
    :initform (make-instance 'nhooks:hook-void))))

(defgeneric process-output (object)
  (:method ((object t))))
(defgeneric process-input (object)
  (:method ((object t))))
(defgeneric process-wait (object))
(defgeneric process-status (object))
(defgeneric description (object))

(defmethod print-object ((p process-mixin) stream)
  (print-unreadable-object (p stream :type t :identity t)
    (format stream "~A (~A)" (description p) (process-status p))))

(defmethod shared-initialize ((p process-mixin) slot-names &key)
  (setf (native-lazy-seq:generator p)
        (lambda ()
          (when (and (process-output p)
                     (open-stream-p (process-output p)))
            (handler-case
                (values (read-line (process-output p)) t)
              (end-of-file ()
                (close p)
                nil)))))
  (call-next-method))

(defmethod initialize-instance :around ((p process-mixin) &key)
  "Handle status change.
We use :AROUND method so that this method is called after the :AFTER
methods of any subclasses, to ensure status change hooks have been
setup before we add it to *jobs*."
  (call-next-method)
  (nhooks:add-hook
   (status-change-hook p)
   (make-instance 'nhooks:handler
                  :fn (lambda ()
                        (unless (eq (process-status p) :running)
                          (deletef *jobs* p)))
                  :name 'remove-from-jobs))
  (when (eq (process-status p) :running)
    (push p *jobs*)))

;;;; Simple process
;; Map 1-to-1 to UNIX process
(defclass simple-process (process-mixin)
  ((process :reader process :initarg :process)
   (description :reader description :initarg :description)))

(defmethod process-output ((p simple-process))
  (sb-ext:process-output (process p)))
(defmethod (setf process-output) (new-value (p simple-process))
  (setf (sb-ext:process-output (process p)) new-value))

(defmethod process-input ((p simple-process))
  (sb-ext:process-input (process p)))
(defmethod (setf process-input) (new-value (p simple-process))
  (setf (sb-ext:process-input (process p)) new-value))

(defmethod process-wait ((p simple-process))
  (sb-ext:process-wait (process p)))

(defmethod process-status ((p simple-process))
  (sb-ext:process-status (process p)))

(defmethod initialize-instance :after ((p simple-process) &key)
  (setf (sb-ext:process-status-hook (process p))
        (lambda (proc)
          (declare (ignore proc))
          (nhooks:run-hook (status-change-hook p)))))

(defmethod close ((p simple-process) &key abort)
  (when abort
    (sb-ext:process-kill (process p) sb-unix:sigterm))
  (sb-ext:process-wait (process p))
  (sb-ext:process-close (process p))
  ;; SB-EXT:PROCESS-CLOSE may leave a closed stream.  Other part of
  ;; our code is not expecting this: `process-input'/`process-output'
  ;; shall either be open stream or nil, therefore we make sure to
  ;; set them to nil.
  (setf (process-input p) nil
        (process-output p) nil)
  t)

;;;; Pipeline
;; Consist of any number of UNIX processes and Lisp function stages
(defclass pipeline (process-mixin)
  ((processes :reader processes :initarg :processes)
   (process-input :accessor process-input :initarg :process-input)
   (process-output :accessor process-output :initarg :process-output)))

(defmethod process-wait ((p pipeline))
  (mapc #'process-wait (processes p)))

(defmethod close ((pipeline pipeline) &key abort)
  (iter (for p in (processes pipeline))
    (close p :abort abort)))

(defmethod initialize-instance :after ((p pipeline) &key)
  (mapc (lambda (child)
          ;; Remove children from *jobs* because the pipeline will be
          ;; put in *jobs* instead.
          (nhooks:remove-hook (status-change-hook child) 'remove-from-jobs)
          (deletef *jobs* child)
          (nhooks:add-hook
           (status-change-hook child)
           (make-instance
            'nhooks:handler
            :fn (lambda ()
                  (nhooks:run-hook (status-change-hook p)))
            :name 'notify-parent)))
        (processes p)))

(defmethod process-status ((p pipeline))
  (if (some (lambda (child) (eq (process-status child) :running))
            (processes p))
      :running
      :exited))

(defmethod description ((p pipeline))
  (serapeum:string-join (mapcar #'description (processes p)) ","))

;;;; Lisp process
(defclass lisp-process (process-mixin)
  ((thread :reader thread)
   (input :accessor process-input)
   (output :accessor process-output)
   (function :reader process-function)
   (status :reader process-status)
   (description :reader description :initarg :description))
  (:default-initargs :description "lisp"))

(defmethod initialize-instance
    ((p lisp-process) &key (function :function)
                        (input :stream) (output :stream) (error *standard-output*))
  (flet ((pipe ()
           (bind (((:values read-fd write-fd) (osicat-posix:pipe)))
             (values (sb-sys:make-fd-stream read-fd :input t :auto-close t)
                     (sb-sys:make-fd-stream write-fd :output t :auto-close t)))))
    (let (stdin stdout)
      (setf (values stdin (slot-value p 'input))
            (if (eq input :stream)
                (pipe)
                (values (read-fd-stream input) nil)))
      (setf (values (slot-value p 'output) stdout)
            (if (eq input :stream)
                (pipe)
                (values nil (write-fd-stream output))))
      (when (eq error :output)
        (setq error stdout))
      (setf (slot-value p 'function) function
            (slot-value p 'status) :running
            (slot-value p 'thread)
            (bt:make-thread
             (lambda ()
               (unwind-protect
                    (funcall function)
                 (close stdin)
                 (close stdout)
                 (setf (slot-value p 'status) :exited)
                 (nhooks:run-hook (status-change-hook p))))
             :initial-bindings
             `((*standard-input* . ,stdin)
               (*standard-output* . ,stdout)
               (*trace-output* . ,error)
               ,@bt:*default-special-bindings*)))))
  (call-next-method))

(defmethod process-wait ((p lisp-process))
  (ignore-errors (bt:join-thread (thread p))))

(defmethod close ((p lisp-process) &key abort)
  (when abort
    (bt:interrupt-thread
     (thread p)
     (lambda ()
       (sb-thread:abort-thread))))
  (ignore-errors (close (process-input p)))
  (ignore-errors (close (process-output p)))
  (ignore-errors (bt:join-thread (thread p))))

;;;; Process I/O streams

(defgeneric read-fd-stream (object)
  (:documentation "Return a fd-stream for reading cotents from OBJECT.
The returned fd-stream is intended to be passed to a child process,
and will be closed after child process creation.")
  (:method ((object (eql :stream))) :stream)
  (:method ((p process-mixin))
    (prog1
        (read-fd-stream (process-output p))
      ;; The consumer takes the output stream exclusively
      (setf (process-output p) nil)))
  (:method ((s sb-sys:fd-stream)) s)
  (:method ((p sequence))
    (native-lazy-seq:with-iterators (element next endp) p
      (bind (((:values read-fd write-fd) (osicat-posix:pipe))
             ((:labels clean-up ())
              (iolib:remove-fd-handlers *fd-watcher-event-base* write-fd)
              (isys:close write-fd))
             ((:labels write-elements ())
              (handler-case
                  (iter
                    (when (funcall endp)
                      (return-from write-elements (clean-up)))
                    (cffi:with-foreign-string
                        ((buf size)
                         (princ-to-string (funcall element)))
                      ;; Replace NUL with Newline
                      (setf (cffi:mem-ref buf :char (1- size)) 10)
                      (osicat-posix:write write-fd buf size))
                    (funcall next))
                (osicat-posix:ewouldblock ())
                (error (c) (describe c) (clean-up)))))
        (setf (isys:fd-nonblock-p write-fd) t)
        (ensure-fd-watcher)
        (iolib:set-io-handler
         *fd-watcher-event-base* write-fd
         :write
         (lambda (fd event error)
           (unless (eq event :write)
             (warn "FD watcher ~A get ~A ~A" fd event error))
           (write-elements)))
        (sb-sys:make-fd-stream read-fd :input t :auto-close t)))))

(defgeneric write-fd-stream (object)
  (:documentation "Return a fd-stream for writing cotents to OBJECT.
The returned fd-stream is intended to be passed to a child process,
and will be closed after child process creation.")
  (:method ((object (eql :stream))) :stream)
  (:method ((object (eql :output))) :output)
  (:method ((p process-mixin))
    (prog1
        (write-fd-stream (process-input p))
      ;; The producer takes the output stream exclusively
      (setf (process-input p) nil)))
  (:method ((s sb-sys:fd-stream)) s)
  (:method ((s stream))
    (bind (((:values read-fd write-fd) (osicat-posix:pipe)))
      (copy-fd-to-stream read-fd s)
      (setf (isys:fd-nonblock-p read-fd) t)
      (sb-sys:make-fd-stream write-fd :output t :auto-close t))))

(defgeneric repl-connect (object)
  (:method ((object t)))
  (:documentation "Display OBJECT more \"thoroughly\" than `print'.
Intended to be used at the REPL top-level to display the primary value
of evualtion results.  See the methods for how we treat different
types of objects."))

(defmethod repl-connect ((p process-mixin))
  "Connect `*standard-input*' and `*standard-output*' to P's input/output."
  (let ((repl-thread (bt:current-thread))
        ;; We take input/output of the process exclusively
        ;; TODO: proper mutex
        read-stream write-stream)
    (when (process-output p)
      (rotatef read-stream (process-output p))
      (copy-fd-to-stream
       read-stream
       *standard-output*
       (lambda ()
         (bt:interrupt-thread
          repl-thread
          (lambda ()
            (ignore-errors (throw 'finish nil)))))))
    (restart-case
        (unwind-protect
             (catch 'finish
               (cond ((process-input p)
                      (rotatef write-stream (process-input p))
                      (loop
                        (handler-case
                            (write-char (read-char) write-stream)
                          (end-of-file ()
                            (close write-stream)
                            (return)))
                        (force-output write-stream)))
                     ((process-output p)
                      ;; wait for output to finish reading
                      (loop (sleep 0.1)))
                     (t (process-wait p))))
          (when read-stream
               (iolib:remove-fd-handlers
                *fd-watcher-event-base*
                (sb-sys:fd-stream-fd read-stream))
               (rotatef (process-output p) read-stream))
          (when write-stream
            (rotatef (process-input p) write-stream)))
      (background () :report "Run job in background.")
      (abort () :report "Abort job."
        (close p :abort t))))
  t)

(defmethod repl-connect ((s native-lazy-seq:lazy-seq))
  "Force evaluation of S and print each elements."
  (native-lazy-seq:with-iterators (element next endp) s
    (iter (until (funcall endp))
      (format t "~A~%" (funcall element))
      (force-output)
      (funcall next)))
  t)

(defun compute-lexifications (body)
  "Return an ALIST that map symbols to their canonical symbols.
This scans BODY to discover any symbol that correspond to Unix file,
but is not canonical.

The returned alist is intended for establishing MACROLET and
SYMBOL-MACROLET bindings to redirect accesses to the canonical symbol,
inspired by the Common Lisp implementation of locale/lexical
environment (Gat, E. Locales: First-Class Lexical Environments for
Common Lisp)."
  (let ((map (make-hash-table)))
    (serapeum:walk-tree
     (lambda (form)
       (when (symbolp form)
         (ignore-some-conditions (file-error)
           (setf (gethash form map) (canonical-symbol form)))))
     body)
    (remove-if (lambda (pair) (eq (car pair) (cdr pair)))
               (alexandria:hash-table-alist map))))

(defmacro toplevel (&body body)
  "Evaluate BODY, but with ergonomics improvements for using as a shell.
1. Use `compute-lexifications' to support relative symbol accesses.
2. Use `repl-connect' to give returned primary value special
treatment if possible."
  (let ((lex (compute-lexifications body)))
    `(let ((result
             (multiple-value-list
              (symbol-macrolet
                  ,(iter (for (from . to) in lex)
                     (collect `(,from ,to)))
                (macrolet
                    ,(iter (for (from . to) in lex)
                       (collect `(,from (&rest args) `(,',to ,@args))))
                  ,@body)))))
       (when (repl-connect (car result))
         (pop result))
       (multiple-value-prog1 (values-list result)
         (nhooks:run-hook *post-command-hook*)))))

;;; Fast loading command

(defvar *fast-load-functions*
  (make-instance 'nhooks:hook-any :combination #'nhooks:combine-hook-until-success))

(defun read-shebang (stream)
  (and (eq (read-char stream nil 'eof) #\#)
       (eq (read-char stream nil 'eof) #\!)))

(defun fast-load-sbcl-shebang (filename args &key input output error directory)
  (let ((stream (open filename :external-format :latin-1)))
    (if (ignore-errors
         (and (read-shebang stream)
              (string= (read-line stream) "/usr/bin/env sbcl --script")))
        (make-instance 'lisp-process
                       :function
                       (lambda ()
                         (unwind-protect
                              (uiop:with-current-directory (directory)
                                (with-standard-io-syntax
                                  (let ((*print-readably* nil) ;; good approximation to SBCL initial reader settings
                                        (sb-ext:*posix-argv* (cons filename args)))
                                    (load stream))))
                           (close stream)))
                       :description (cdr (ppath:split filename))
                       :input input :output output :error error)
        (progn
          (close stream)
          nil))))

(nhooks:add-hook *fast-load-functions* 'fast-load-sbcl-shebang)

;;; Command syntax

(defgeneric to-argument (object)
  (:documentation "Convert Lisp OBJECT to Unix command argument.")
  (:method ((symbol symbol))  (prin1-to-string symbol))
  (:method ((string string)) string)
  (:method ((list list))
    "Elements of LIST are concatenated together.
This implies: 1. if a command output a single line, its result can be
used in arguments like POSIX shell command substitution.
2. One can split components of arguments to a list, e.g.
writing (--key= ,value)."
    (mapconcat #'to-argument list "")))

(defun split-args (args)
  "Split ARGS into keyword argument plist and other arguments.
Return two values: the plist of keywords and the list of other
arguments.
Example: (split-args a b :c d e) => (:c d), (a b e)"
  (iter (while args)
    (if (keywordp (car args))
        (progn
          (collect (car args) into plist)
          (collect (cadr args) into plist)
          (setq args (cddr args)))
        (progn
          (collect (car args) into rest)
          (setq args (cdr args))))
    (finally (return (values plist rest)))))

(defun execute-command (command args &key (input :stream) (output :stream) (error *standard-output*))
  (let ((directory (uiop:absolute-pathname-p (to-dir (unconvert-case (package-name *package*)))))
        (path (ensure-path command))
        (args (map 'list #'to-argument args))
        input-1 output-1 error-1)
    (or (nhooks:run-hook *fast-load-functions* path args
                         :input input :output output :error error
                         :directory directory)
        (unwind-protect
             (progn
               (psetq input-1 (read-fd-stream input)
                      output-1 (write-fd-stream output)
                      error-1 (write-fd-stream error))
               (make-instance
                'simple-process
                :process
                (sb-ext:run-program
                 path args
                 :wait nil
                 :input input-1 :output output-1 :error error-1
                 :directory directory
                 :environment (current-env))
                :description (princ-to-string command)))
          (when (streamp input-1)
            (close input-1))
          (when (streamp output-1)
            (close output-1))
          (when (streamp error-1)
            (close error-1))))))

(defun command-macro (form env)
  (declare (ignore env)
           (sb-c::lambda-list (&rest args)))
  (bind (((command . args) form)
         ((:values plist command-args) (split-args args)))
    ;; The following macrolet make ,@<some-sequence> work, just like
    ;; ,@<some-list>.  This is done so that users can write
    ;; ,@<some-unix-command> easily, similar to POSIX shell command
    ;; substitutions.
    `(macrolet ((fare-quasiquote::append (&rest args)
                  `(append ,@ (mapcar (lambda (arg) `(coerce ,arg 'list)) args)))
                (fare-quasiquote::quote (&rest x)
                  `',(append (butlast x) (car (last x))
                             (coerce (cdr (last x)) 'list))))
       (execute-command
        ',command
        ,(list 'fare-quasiquote:quasiquote command-args)
        ,@plist))))

(defun placeholder-p (form)
  (and (symbolp form) (string= (symbol-name form) "_")))

(defmacro pipe (&rest forms)
  `(let (%processes)
     (push ,(car forms) %processes)
     ,@ (mapcar (lambda (form)
                  (if-let ((placeholder (and (listp form) (find-if #'placeholder-p form))))
                    `(push ,(substitute '(car %processes) placeholder form)
                           %processes)
                    `(push (,@form :input (car %processes))
                           %processes)))
                (cdr forms))
     (setq %processes (nreverse %processes))
     (make-instance 'pipeline
                    :processes (remove-if-not
                                (lambda (p) (typep p 'process-mixin))
                                %processes)
                    :process-input (process-input (car %processes))
                    :process-output (process-output (lastcar %processes)))))

;;; Built-in commands

(defmacro cd (&optional (path "~"))
  `(setq *package* (mount-directory ,(list 'fare-quasiquote:quasiquote path))))

;;; Reader syntax hacks

(defun call-without-read-macro (char thunk)
  (bind (((:values function terminating-p) (get-macro-character char)))
    (unwind-protect
         (progn (set-macro-character char nil t)
                (funcall thunk))
      (set-macro-character char function terminating-p))))

(defun dot-read-macro (stream char)
  (flet ((delimiter-p (c)
           (or (eq c 'eof) (sb-impl:token-delimiterp c)))
         (unread (c)
           (unless (eq c 'eof) (unread-char c stream)))
         (standard-read ()
           (call-without-read-macro #\. (lambda () (read stream)))))
    (if (package-path *package*)
        (let ((char-1 (read-char stream nil 'eof))
              (char-2 (read-char stream nil 'eof)))
          (cond
            ((delimiter-p char-1)
             (unread char-1)
             (intern "./"))
            ((and (eq char-1 #\.) (delimiter-p char-2))
             (unread char-2)
             (intern "../"))
            (t (unread char-2)
               (unread char-1)
               (unread char)
               (standard-read))))
        (progn (unread char)
               (standard-read)))))

(defun slash-read-macro (stream char)
  "If we're reading a symbol that designates an *existing* Unix file,
return its canonical symbol.  Otherwise return the original symbol.
Currently, this is intended to be used for *both* /path syntax and
~user/path syntax."
  (unread-char char stream)
  (let ((symbol (call-without-read-macro char (lambda () (read stream)))))
    (if (symbol-home-p symbol)
        (handler-case
            (canonical-symbol symbol)
          (file-error () symbol))
        symbol)))

(defun dollar-read-macro (stream char)
  "If we're reading a symbol that starts with `$', rehome it to
`UNIX-IN-LISP.COMMON' and call `ensure-env-var'."
  (unread-char char stream)
  (let ((symbol (call-without-read-macro char (lambda () (read stream)))))
    (when (and (symbol-home-p symbol) (string-prefix-p "$" (symbol-name symbol)))
      (unintern symbol)
      (setq symbol (intern (symbol-name symbol) "UNIX-IN-LISP.COMMON"))
      (export symbol "UNIX-IN-LISP.COMMON")
      (ensure-env-var symbol))
    symbol))

(named-readtables:defreadtable unix-in-lisp
  (:merge :fare-quasiquote)
  (:macro-char #\. 'dot-read-macro t)
  (:macro-char #\/ 'slash-read-macro t)
  (:macro-char #\~ 'slash-read-macro t)
  (:macro-char #\$ 'dollar-read-macro t)
  (:case :invert))

(defun unquote-reader-hook (orig thunk)
  (if (= fare-quasiquote::*quasiquote-level* 0)
      (let ((fare-quasiquote::*quasiquote-level* 1))
        (funcall orig thunk))
      (funcall orig thunk)))

;;; Environment variables

(defvar *env-vars* nil "An ALIST that maps symbols to Unix environment variable name strings.")

(defun ensure-env-var (symbol &optional unix-name)
  "Associate SYMBOL with Unix environment variable with UNIX-NAME.
If UNIX-NAME is nil or not provided, the SYMBOL must follow $FOO naming
convention and UNIX-NAME defaults to FOO."
  (unless (string-prefix-p "$" (symbol-name symbol))
    (warn "~S is being defined as a Unix environment variable, but its name does
not follow usual convention (like $~A)." symbol (symbol-name symbol)))
  (unless unix-name
    (if (string-prefix-p "$" (symbol-name symbol))
        (setq unix-name (subseq (symbol-name symbol) 1))
        (error "Please supply a Unix environment variable name for ~S, or use a symbol
that follow usual naming convention (like $~A)." symbol (symbol-name symbol))))
  (proclaim `(special ,symbol))
  (unless (boundp 'symbol)
    (setf (symbol-value symbol) (or (uiop:getenv unix-name) "")))
  (setf (assoc-value *env-vars* symbol) unix-name)
  symbol)

(defun current-env ()
  "Construct Unix environment according to Lisp symbol bindings.
The result is a list of strings with the form \"VAR=VALUE\", as in
environ(7)."
  (iter (for (symbol . name) in *env-vars*)
    (when (boundp symbol)
      (collect (concat name "=" (princ-to-string (symbol-value symbol)))))))

(defun synchronize-env-to-unix ()
  "Update the Unix environment of the Lisp image to reflect current Lisp
symbol bindings."
  (iter (for (symbol . name) in *env-vars*)
    (if (boundp symbol)
        (setf (uiop:getenv name) (princ-to-string (symbol-value symbol)))
        (sb-posix:unsetenv name))))

(nhooks:add-hook *post-command-hook* 'synchronize-env-to-unix)

;;; Installation/uninstallation

(define-condition already-installed (error) ()
  (:report "There seems to be a previous Unix in Lisp installation."))

(defun get-env-names ()
  (mapcar (lambda (s)
            (subseq s 0 (position #\= s)))
          (sb-ext:posix-environ)))

(defun ensure-common-package (package-name)
  (bind ((use-list '(:unix-in-lisp :unix-in-lisp.path
                     :serapeum :alexandria :cl))
         (package (uiop:ensure-package package-name
                                       :mix use-list
                                       :reexport use-list)))
    (mapc (lambda (name)
            (let ((symbol (intern (concat "$" name) package) ))
              (ensure-env-var symbol name)
              (export symbol package)))
          (get-env-names))
    package))

(defun install (&optional skip-installed)
  (when (find-package "UNIX-IN-LISP.PATH")
    (if skip-installed
        (return-from install nil)
        (restart-case (error 'already-installed)
          (continue () :report "Uninstall first, then reinstall." (uninstall))
          (reckless-continue () :report "Install on top of it."))))
  (let ((*readtable* (named-readtables:find-readtable 'unix-in-lisp)))
    ;; Make UNIX-IN-LISP.COMMON first because FS packages in $PATH will
    ;; circularly reference UNIX-IN-LISP.COMMON
    (make-package "UNIX-IN-LISP.COMMON")
    (let ((packages (iter (for path in (uiop:getenv-pathnames "PATH"))
                      (handler-case
                          (collect (mount-directory path))
                        (file-error (c) (warn "Failed to mount ~A in $PATH: ~A" path c))))))
      (uiop:ensure-package "UNIX-IN-LISP.PATH" :mix packages :reexport packages))
    (ensure-common-package "UNIX-IN-LISP.COMMON")
    (defmethod print-object :around ((symbol symbol) stream)
      (if *print-escape*
          (cond ((eq (find-symbol (symbol-name symbol) *package*) symbol) (call-next-method))
                ((not (symbol-package symbol)) (call-next-method))
                ((package-path (symbol-package symbol))
                 (write-string (symbol-path symbol) stream))
                (t (call-next-method)))
          (call-next-method)))
    (cl-advice:add-advice :around 'fare-quasiquote:call-with-unquote-reader 'unquote-reader-hook)
    (cl-advice:add-advice :around 'fare-quasiquote:call-with-unquote-splicing-reader 'unquote-reader-hook)
    (ensure-fd-watcher)
    t))

(defun uninstall ()
  (cl-advice:remove-advice :around 'fare-quasiquote:call-with-unquote-reader 'unquote-reader-hook)
  (cl-advice:remove-advice :around 'fare-quasiquote:call-with-unquote-splicing-reader 'unquote-reader-hook)
  (when-let (method (find-method #'print-object '(:around) '(symbol t) nil))
    (remove-method #'print-object method))
  (mapc
   (lambda (p)
     (when (package-path p)
       (handler-bind ((package-error #'continue))
         (delete-package p))))
   (list-all-packages))
  (when (find-package "UNIX-IN-LISP.COMMON")
    (delete-package "UNIX-IN-LISP.COMMON"))
  (when (find-package "UNIX-IN-LISP.PATH")
    (delete-package "UNIX-IN-LISP.PATH"))
  (values))

(defun setup ()
  (install t)
  (named-readtables:in-readtable unix-in-lisp)
  (cd "~/")
  (values))
