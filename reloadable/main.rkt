#lang racket/base

(provide (struct-out reloadable-entry-point)
         reload-poll-interval
         set-reload-poll-interval!
         reload-failure-retry-delay
         reload!
         make-reloadable-entry-point
         lookup-reloadable-entry-point
         reloadable-entry-point->procedure
         make-persistent-state)

(require racket/set)
(require racket/match)
(require racket/rerequire)

(define reload-poll-interval 0.5) ;; seconds
(define reload-failure-retry-delay (make-parameter 5)) ;; seconds

(struct reloadable-entry-point (name
                                module-path
                                identifier-symbol
                                on-absent
                                [value #:mutable])
        #:prefab)

(define reloadable-entry-points (make-hash))
(define persistent-state (make-hash))

(define (set-reload-poll-interval! v)
  (set! reload-poll-interval v))

(define (reloader-main)
  (let loop ()
    (match (sync (handle-evt (thread-receive-evt)
                             (lambda (_) (thread-receive)))
                 (if reload-poll-interval
                     (handle-evt (alarm-evt (+ (current-inexact-milliseconds)
                                               (* reload-poll-interval 1000)))
                                 (lambda (_) (list #f 'reload)))
                     never-evt))
      [(list ch 'reload)
       (define result (do-reload!))
       (when (not result) (sleep (reload-failure-retry-delay)))
       (when ch (channel-put ch result))])
    (loop)))

(define reloader-thread (thread reloader-main))

(define (reloader-rpc . request)
  (define ch (make-channel))
  (thread-send reloader-thread (cons ch request))
  (channel-get ch))

(define (reload!) (reloader-rpc 'reload))

;; Only to be called from reloader-main
(define (do-reload!)
  (define module-paths (for/set ((e (in-hash-values reloadable-entry-points)))
                         (reloadable-entry-point-module-path e)))
  (with-handlers ((exn:fail?
                   (lambda (e)
                     (log-error "*** WHILE RELOADING CODE***\n~a"
                                (parameterize ([current-error-port (open-output-string)])
                                  ((error-display-handler) (exn-message e) e)
                                  (get-output-string (current-error-port))))
                     #f)))
    (for ((module-path (in-set module-paths)))
      (dynamic-rerequire module-path #:verbosity 'all))
    (for ((e (in-hash-values reloadable-entry-points)))
      (match-define (reloadable-entry-point _ module-path identifier-symbol on-absent _) e)
      (define new-value (if on-absent
                            (dynamic-require module-path identifier-symbol on-absent)
                            (dynamic-require module-path identifier-symbol)))
      (set-reloadable-entry-point-value! e new-value))
    #t))

(define (make-reloadable-entry-point name module-path [identifier-symbol name]
                                     #:on-absent [on-absent #f])
  (define key (list module-path name))
  (hash-ref reloadable-entry-points
            key
            (lambda ()
              (define e (reloadable-entry-point name module-path identifier-symbol on-absent #f))
              (hash-set! reloadable-entry-points key e)
              e)))

(define (lookup-reloadable-entry-point name module-path)
  (hash-ref reloadable-entry-points
            (list module-path name)
            (lambda ()
              (error 'lookup-reloadable-entry-point
                     "Reloadable-entry-point ~a not found in module ~a"
                     name
                     module-path))))

(define (reloadable-entry-point->procedure e)
  (make-keyword-procedure
   (lambda (keywords keyword-values . positionals)
     (keyword-apply (reloadable-entry-point-value e)
                    keywords
                    keyword-values
                    positionals))))

(define (make-persistent-state name initial-value-thunk)
  (hash-ref persistent-state
            name
            (lambda ()
              (define value (initial-value-thunk))
              (define handler
                (case-lambda
                  [() value]
                  [(new-value)
                   (set! value new-value)
                   value]))
              (hash-set! persistent-state name handler)
              handler)))
