#lang racket/base
(require racket/stxparam
         racket/system
         racket/string
         racket/format
         racket/port
         racket/contract/base
         (for-syntax racket/base))

(struct container (name))

(provide
 (contract-out
  [docker-image-id
   ((#:name string?)
    ()
    . ->* .
    (or/c string? #f))]

  [docker-image-remove
   ((#:name string?)
    ()
    . ->* .
    void?)]
  
  [docker-build
   ((#:name string?
     #:content path-string?)
    (#:platform (or/c #f string?))
    . ->* .
    void?)]
  
  [docker-create
   ((#:name string?
     #:image-name string?)
    (#:platform (or/c #f string?)
     #:network (or/c #f string?)
     #:volumes (listof (list/c path-string? string? (or/c 'ro 'rw)))
     #:memory-mb (or/c #f exact-nonnegative-integer?)
     #:swap-mb (or/c #f exact-nonnegative-integer?)
     #:envvars (hash/c string? string?)
     #:replace? boolean?)
    . ->* .
    string?)]

  [docker-id
   ((#:name string?)
    ()
    . ->* .
    (or/c string? #f))]
  
  [docker-running?
   ((#:name string?)
    ()
    . ->* .
    boolean?)]
  
  [docker-remove
   ((#:name string?)
    ()
    . ->* .
    void?)]
  
  [docker-start
   ((#:name string?)
    ()
    . ->* .
    void?)]
  
  [docker-stop
   ((#:name string?)
    ()
    . ->* .
    void?)]
  
  [docker-exec
   ((#:name string?
     string?)
    (#:mode (or/c 'error 'result))
    #:rest (listof string?)
    . ->* .
    (or/c boolean? void?))]

  [docker-copy
   ((#:name string?
     #:src path-string?
     #:dest path-string?)
    (#:mode (or/c 'error 'result))
    . ->* .
    (or/c boolean? void?))]))

(define-syntax-parameter who #f)

(define-for-syntax (make-who sym)
  (lambda (stx)
    (syntax-case stx()
      [(_ arg ...) #`('#,sym arg ...)]
      [_ #`'#,sym])))

(define-syntax-rule (define/who (id . args) body ...)
  (define (id . args)
    (syntax-parameterize ([who (make-who 'id)])
      body ...)))

(define (failed who what name)
  (error who "~a\n  name: ~e" what name))

(define-syntax-rule (with-no-stdout e0 e ...)
  (parameterize ([current-output-port (open-output-nowhere)])
    e0 e ...))

(define docker (find-executable-path "docker"))

(define (system*/string . args)
  (define s (open-output-string))
  (and
   (parameterize ([current-output-port s])
     (apply system* args))
   (get-output-string s)))

(define/who (docker-image-id #:name name)
  (define reply
    (system*/string docker "image" "ls" "--format" "{{.ID}}" name))
  (unless reply (failed who "id query failed" name))
  (extract-one-id who reply))

(define (extract-one-id who reply)
  (cond
    [(equal? reply "") #f]
    [(regexp-match #rx"^([a-f0-9]*)\n$" reply)
     => (lambda (m) (cadr m))]
    [else
     (error who "unexpected docker output\n  output: ~s" reply)]))

(define/who (docker-image-remove #:name name)
  (define id (docker-image-id #:name name))
  (unless id
    (error who "no such image to remove\n  name: ~e" name))
  (unless (system* docker "image" "rm" name)
    (failed who "remove failed" name)))

(define/who (docker-build #:name name
                          #:content content-dir
                          #:platform [platform #f])
  (unless (apply system*
                 (append
                  (list docker "build" "--tag" name "--rm")
                  (if platform (list "--platform" platform) null)
                  (list content-dir)))
    (failed who "build failed" name)))

(define/who (docker-create #:name name
                           #:image-name image-name
                           #:platform [platform #f]
                           #:network [network #f]
                           #:volumes [volumes '()]
                           #:memory-mb [memory-mb #f]
                           #:swap-mb [swap-mb #f]
                           #:envvars [envvars (hash)]
                           #:replace? [replace? #f])
  (when replace?
    (define id (docker-id #:name name))
    (when id
      (when (docker-running? #:name name)
        (docker-stop #:name name))
      (docker-remove #:name name)))
  (define reply
    (apply system*/string
           (append
            (list docker "container" "create" "-i" "-t" "--name" name)
            (if platform
                (list "--platform" platform)
                null)
            (if network
                (list "--network" network)
                null)
            (for/list ([vol (in-list volumes)])
              (~a "--volume=" (car vol) ":" (cadr vol) ":" (caddr vol)))
            (for/list ([key (in-hash-keys envvars)])
              (~a "-e " key "=" (hash-ref envvars key)))
            (if (or memory-mb swap-mb)
                (list (format "--memory=~am" (or memory-mb swap-mb))
                      (format "--memory-swap=~am" (+ (or memory-mb swap-mb) (or swap-mb memory-mb))))
                null)
            (list image-name))))
  (unless reply (failed who "create failed" name))
  (extract-one-id who reply))

(define/who (docker-id #:name name)
  (define reply (system*/string docker "container" "ls" "-a" "--filter" (~a "name=^" name "$") "--format" "{{.ID}}"))
  (unless reply (failed who "existence query failed" name))
  (extract-one-id who reply))

(define/who (docker-running? #:name name)
  (define running-reply (system*/string docker "container" "ls" "--filter" (~a "name=^" name "$") "--format" "{{.ID}}"))
  (define running-id (extract-one-id who running-reply))
  (and running-id #t))

(define/who (docker-remove #:name name)
  (unless (with-no-stdout (system* docker "container" "rm" name))
    (failed who "remove failed" name)))

(define/who (docker-start #:name name)
  (unless (with-no-stdout (system* docker "container" "start" name))
    (failed who "start failed" name)))

(define/who (docker-stop #:name name)
  (unless (with-no-stdout (system* docker "container" "stop" name))
    (failed who "stop failed" name)))

(define/who (docker-exec #:name name
                         #:mode [mode 'error]
                         command . args)
  (define ok? (apply system* docker "container" "exec" name command args))
  (case mode
    [(result) ok?]
    [else
     (unless ok?
       (error who "command failed\n  name: ~e\n  command: ~e"
              name
              (apply ~e args)))]))

(define/who (docker-copy #:name name
                         #:src src
                         #:dest dest
                         #:mode [mode 'error])
  (define ok?
    (system* docker "cp" src dest))
  (case mode
    [(error)
     (unless ok?
       (error who "copy failed\n  name: ~e\n  src: ~e\n  dest: ~e" name src dest))]
    [else ok?]))
