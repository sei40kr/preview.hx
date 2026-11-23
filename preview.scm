(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/ext.scm")

(provide preview
         preview-stop
         preview-register!
         preview-set-open-command!)

;; language id -> (list args url-fn timeout-seconds)
(define *tools* (hash))

;; Running previews as a list of (list doc-id child url gen).
;; A list rather than a hash because DocumentId only defines equality.
;; url stays #f until the tool prints one; gen tells a restarted preview apart
;; from callbacks of the old process.
(define *procs* '())
(define *gen* 0)

(define *open-command* (if (equal? (current-os!) "macos") "open" "xdg-open"))

;;@doc
;; Set the command used to open a preview URL. Defaults to xdg-open (open on macOS).
(define (preview-set-open-command! cmd)
  (set! *open-command* cmd))

(define (default-url line)
  (let loop ([words (split-whitespace line)])
    (cond
      [(null? words) #f]
      [(or (starts-with? (car words) "http://") (starts-with? (car words) "https://")) (car words)]
      [else (loop (cdr words))])))

;;@doc
;; Register a preview tool for a helix language id.
;; "{file}" in args is replaced with the absolute path of the buffer's file.
;; #:url takes a stdout line and returns the preview URL or #f; by default the
;; first http(s):// word is used. #:timeout is in seconds.
;;
;; ```scheme
;; (preview-register! "markdown" '("mdp" "--no-open" "{file}"))
;; ```
(define (preview-register! language args #:url [url-fn default-url] #:timeout [timeout 10])
  (set! *tools* (hash-insert *tools* language (list args url-fn timeout))))

(define (lookup doc)
  (let loop ([ps *procs*])
    (cond
      [(null? ps) #f]
      [(equal? (car (car ps)) doc) (car ps)]
      [else (loop (cdr ps))])))

(define (lookup-gen gen)
  (let loop ([ps *procs*])
    (cond
      [(null? ps) #f]
      [(equal? (list-ref (car ps) 3) gen) (car ps)]
      [else (loop (cdr ps))])))

(define (remove-entry! entry)
  (set! *procs* (filter (lambda (e) (not (equal? (list-ref e 3) (list-ref entry 3)))) *procs*)))

(define (kill-entry! entry)
  (remove-entry! entry)
  (kill (list-ref entry 1)))

(define (open-url url)
  (define result (spawn-process (command *open-command* (list url))))
  ;; Ends in set-status!/set-error! because helix prints a typed command's return value.
  (if (Ok? result)
      (let ([child (Ok->value result)])
        (spawn-native-thread (lambda () (wait child)))
        (set-status! (string-append "preview: " url)))
      (set-error! (string-append "preview: failed to run " *open-command*))))

(define (on-url gen url)
  (define entry (lookup-gen gen))
  (when (and entry (not (list-ref entry 2)))
    (set! *procs*
          (map (lambda (e) (if (equal? (list-ref e 3) gen) (list (car e) (list-ref e 1) url gen) e))
               *procs*))
    (open-url url)))

(define (on-exit gen)
  (define entry (lookup-gen gen))
  (when entry
    (remove-entry! entry)
    (set-error! "preview: tool exited")))

(define (on-timeout gen)
  (define entry (lookup-gen gen))
  (when (and entry (not (list-ref entry 2)))
    (kill-entry! entry)
    (set-error! "preview: timed out waiting for the preview URL")))

;; Reads stdout off the main thread; keeps draining after the URL so the pipe
;; never fills up and an exit is still noticed.
(define (watch-stdout gen out url-fn)
  (spawn-native-thread
   (lambda ()
     (let loop ([found #f])
       (define line (read-line-from-port out))
       (if (eof-object? line)
           (hx.with-context (lambda () (on-exit gen)))
           (let ([url (and (not found) (url-fn (trim-end line)))])
             (when url
               (hx.with-context (lambda () (on-url gen url))))
             (loop (or found url))))))))

(define (start doc path tool)
  (define args (map (lambda (a) (string-replace a "{file}" path)) (list-ref tool 0)))
  (define result
    (~> (command (car args) (cdr args))
        (with-current-dir (parent-name path))
        with-stdin-piped
        with-stdout-piped
        ;; Inheriting stderr would draw over the editor.
        (with-stderr (open-output-file "/dev/null" #:exists 'update))
        spawn-process))
  (if (Err? result)
      (set-error! (string-append "preview: failed to run " (car args)))
      (let ([child (Ok->value result)])
        (set! *gen* (+ *gen* 1))
        (set! *procs* (cons (list doc child #f *gen*) *procs*))
        (watch-stdout *gen* (child-stdout child) (list-ref tool 1))
        (let ([gen *gen*])
          (enqueue-thread-local-callback-with-delay (* (list-ref tool 2) 1000)
                                                    (lambda () (on-timeout gen))))
        (set-status! (string-append "preview: started " (car args))))))

;;@doc
;; Start the preview tool for the current buffer and open it in the browser.
;; If it is already running, just open the browser again.
(define (preview)
  (define doc (editor->doc-id (editor-focus)))
  (define path (editor-document->path doc))
  (define lang (editor-document->language doc))
  (define tool (and lang (hash-try-get *tools* lang)))
  (define entry (lookup doc))
  (cond
    [(not path) (set-error! "preview: buffer has no file")]
    [(not tool) (set-error! (string-append "preview: no tool registered for " (or lang "this buffer")))]
    [(and entry (list-ref entry 2)) (open-url (list-ref entry 2))]
    [entry (set-status! "preview: still starting")]
    [else (start doc path tool)]))

;;@doc
;; Stop the preview tool of the current buffer.
(define (preview-stop)
  (define entry (lookup (editor->doc-id (editor-focus))))
  (if entry
      (begin
        (kill-entry! entry)
        (set-status! "preview: stopped"))
      (set-error! "preview: not running")))

(register-hook 'document-closed
               (lambda (e)
                 (define entry (lookup (doc-closed-id e)))
                 (when entry
                   (kill-entry! entry))))

(preview-register! "markdown" '("mdp" "--no-open" "{file}"))
