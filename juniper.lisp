;;;; juniper.lisp

(in-package #:juniper)

;; those are used by the generator internally and should be globally unbound
(defvar *schema*)
(defvar *proto*)
(defvar *url*)
(defvar *base-path*)
(defvar *accept-header*)
(defvar *endpoint*)
(defvar *path-params*)

;; can't have them as parameters to the generated functions lest them conflict
;; with a parameter in the schema; unsure if using dynamic variables for this
;; is very ideal though
;; *drakma-extra-args* also breaks the abstraction and ties us up to drakma

;; those can be used to change the behaviour of the generated functions at runtime
(defvar *host*)
(defvar *port*)
(defvar *drakma-extra-args* nil)

;;; utilities
;; `mkstr` and `symb` are from Let over Lambda, which I believe were taken from On Lisp
(eval-when (compile load eval)
  (defun mkstr (&rest args)
    (with-output-to-string (s)
      (dolist (a args) (princ a s))))

  (defun symb (&rest args)
    (values (intern (apply #'mkstr args))))

  (defun lisp-symbol (val)
    (intern (string-upcase (kebab:to-lisp-case (string val))))))

(defun assoc-field (item alist)
  "Looks up the value associated with `item` in `alist`"
  (cdr (assoc item alist)))

(defun field (item &optional (alist *schema*))
  "Looks up the value associated with `item` in `alist` (defaults to schema currently being processed), follows (and automatically fetches and parses) `$ref`s as needed"
  (assoc-field item alist)) ; FIXME

;;; generator code

(defun function-for-op (op &aux required optional assistance-code)
  (with-gensyms (url query-params headers body uses-form parsed-url
		 response response-string stream)
    (labels ((parse-parameter (param)
	       (let* ((name (field :|name| param))
		      (symbolic-name (lisp-symbol name))
		      (supplied-p (symb symbolic-name '-supplied-p))
		      (is-required (field :|required| param))
		      (in (field :|in| param)))
		 (if is-required
		     (push symbolic-name required)
		     (push `(,symbolic-name nil ,supplied-p) optional))
		 (push
		  `(if ,(if is-required t supplied-p)
		       ,(switch (in :test #'string=)
			  ("path"
			   `(setf ,url
				  (cl-ppcre:regex-replace ,(format nil "{~a}" name)
							  ,url (mkstr ,symbolic-name))))
			  ("query"
			   `(push (cons ,name (mkstr ,symbolic-name))
					,query-params))
			  ("header"
			   `(push (cons ,name (mkstr ,symbolic-name))
				  ,headers))
			  ("body"
			   `(setf ,body
				  (concatenate 'string ,body
					       (json:encode-json-to-string ,symbolic-name))))
			  ("formData"
			   `(progn
			      (setf ,uses-form t)
			      (push (cons ,name (mkstr ,symbolic-name))
				    ,query-params)))
			  (otherwise
			   (warn "Don't know how to handle parameters in ~a." in))))
		  assistance-code))))
      (mapcar #'parse-parameter (append *path-params*
					(field :|parameters| (cdr op))))
      (unless (zerop (length optional))
	(push '&key optional))
      `(defun ,(lisp-symbol (field :|operationId| (cdr op)))
	   ,(append required optional
	     `(&aux (,url ,*url*)
		 ,headers ,query-params ,body ,uses-form))
	 ,(field :|summary| (cdr op))
	 ,@assistance-code
	 (let ((,parsed-url (puri:uri ,url)))
	   (when (boundp 'juniper:*host*)
	     (setf (puri:uri-host ,parsed-url) juniper:*host*))
	   (when (boundp 'juniper:*port*)
	     (setf (puri:uri-port ,parsed-url) juniper:*port*))
	   (let* ((,response
		    (apply #'drakma:http-request
			   (puri:render-uri ,parsed-url nil)
			   :method ,(intern (string-upcase
					     (string (car op)))
					    'keyword)
			   :parameters ,query-params
			   :additional-headers ,headers
			   :form-data ,uses-form
			   :content-type "application/json" ; FIXME
			   :content ,body
			   :accept ,*accept-header*
			   juniper:*drakma-extra-args*))
		  (,response-string
		    ; FIXME extract encoding from response headers?
		    (flexi-streams:octets-to-string ,response
						    :external-format :utf-8)))
	     (unless (zerop (length ,response-string))
	       ; FIXME don't assume json
	       ; FIXME there's likely a way to get a stream from the connection directly
	       (with-input-from-string (,stream ,response-string)
		 (json:decode-json ,stream)))))))))

(defun swagger-path-bindings (path &aux (name (car path)) (ops (cdr path)))
  (let* ((*endpoint* (string name))
	 ; FIXME we have puri as a dependency and still construct urls by hand
	 (*url* (format nil "~a://~a~a~a" *proto* *host* *base-path* *endpoint*))
	 (*path-params* (field :|parameters| ops)))
    `(progn
       ,@(mapcar #'function-for-op ops))))

(defun swagger-bindings ()
  `(progn
     ,@(mapcar #'swagger-path-bindings (field :|paths|))))

(defun bindings-from-stream (stream &key proto host base-path accept-header)
  (let* ((cl-json:*json-identifier-name-to-lisp* (lambda (x) x)) ; avoid mangling names by accident
	 (*schema* (json:decode-json stream))

	 (version (or (field :|swagger|)
		      (field :|openapi|)
		      (error "Cannot find version field in schema.")))

	 ; FIXME we only use the first protocol presented
	 (*proto* (or proto (car (field :|schemes|))
		      (error "Cannot find protocol in schema.")))
	 (*host* (or host (field :|host|)
		     (error "Cannot find host in schema.")))
	 (*base-path* (or base-path (field :|basePath|) "/"))
	 (*accept-header* (or accept-header "application/json")))
    (switch (version :test #'string=)
      ("2.0" (swagger-bindings))
      (otherwise
       (error "Unsupported swagger/OpenAPI version ~a." version)))))

;;;

(defmacro defsource (name args &body body)
  (with-gensyms (dispatched options return)
    (setf args (cons name args))
    `(defmacro ,(symb 'bindings-from- name) (,@args &rest ,options
					     &key proto host base-path accept-header
					     &aux ,dispatched ,return)
       (declare (ignore proto host base-path accept-header))
       (labels ((dispatch-bindings (stream)
		  (when ,dispatched
		    (error "Trying to dispatch bindings more than once, this is a bug on Juniper."))
		  (setf ,dispatched t)
		  (apply #'bindings-from-stream stream ,options)))
	 (setf ,return (progn ,@body))
	 (unless ,dispatched
	   (error "Source never dispatched stream to generator, this is a bug on Juniper."))
	 ,return))))

(defsource file ()
  "Generates bindings from local file at `file`"
  (with-open-file (stream (eval file))
    (dispatch-bindings stream)))

(defsource json ()
  "Generates bindings from a literal JSON string"
  (with-input-from-string (stream (eval json))
    (dispatch-bindings stream)))

(defsource url ()
  "Generates bindings for remote schema at `url`"
   ; FIXME there has to be a better way to do this
  (with-input-from-string (stream (flexi-streams:octets-to-string
				   (drakma:http-request (eval url))))
    (dispatch-bindings stream)))

;(bindings-from-url "https://petstore.swagger.io/v2/swagger.json")
