#lang racket/base

(require racket/contract
         racket/string
         racket/system)

(provide
 (contract-out
  [start-vbox-vm
   ((string?)
    (#:max-vms real?
               #:dry-run? any/c
               #:log-status (string? #:rest any/c . -> . any)
               #:pause-seconds real?)
    . ->* .
    void?)]
  [stop-vbox-vm
   ((string?)
    (#:save-state? any/c
                   #:dry-run? any/c
                   #:log-status (string? #:rest any/c . -> . any))
    . ->* .
    void?)]
  [take-vbox-snapshot (string? string? . -> . void?)]
  [restore-vbox-snapshot (string? string? . -> . void?)]
  [delete-vbox-snapshot (string? string? . -> . void?)]
  [exists-vbox-snapshot? (string? string? . -> . boolean?)]
  [get-vbox-snapshot-uuid (string? string? . -> . (or/c #f string?))]
  [import-vbox-vm (->* (path-string?)
                       (#:name (or/c false/c non-empty-string?)
                        #:cpus (or/c false/c exact-positive-integer?)
                        #:memory (or/c false/c exact-positive-integer?))
                       void?)]))

(define VBoxManage (find-executable-path "VBoxManage"))
(define use-headless? #t)

(define (system*/string . args)
  (define s (open-output-string))
  (and
   (parameterize ([current-output-port s])
     (apply system* args))
   (get-output-string s)))

(define (check-vbox-exe who)
  (unless (path? VBoxManage)
    (raise-arguments-error who "cannot find VBoxManage executable")))

(define (vbox-state vbox)
  (define s (or (system*/string VBoxManage "showvminfo" vbox) ""))
  (define m (regexp-match #rx"(?m:^State:[ ]*([a-z]+(?: [a-z]+)*))" s))
  (define state (and m (string->symbol (cadr m))))
  (case state
    [(|powered off| aborted) 'off]
    [(running saved paused) state]
    [(restoring) (vbox-state vbox)]
    [else
     (eprintf "~a\n" s)
     (error 'vbox-state "could not get virtual machine status: ~s" vbox)]))

(define (vbox-control vbox what)
  (system* VBoxManage "controlvm" vbox what))

(define (vbox-start vbox)
  (apply system* VBoxManage "startvm" vbox
         (if use-headless?
             '("--type" "headless")
             null))
  ;; wait for the machine to get going:
  (let loop ([n 0])
    (unless (eq? 'running (vbox-state vbox))
      (unless (= n 20)
        (sleep 0.5)
        (loop (add1 n))))))

(define call-with-vbox-lock
  (let ([s (make-semaphore 1)]
        [lock-cust (current-custodian)])
    (lambda (thunk)
      (define t (current-thread))
      (define ready (make-semaphore))
      (define done (make-semaphore))
      (parameterize ([current-custodian lock-cust])
        (thread (lambda ()
                  (semaphore-wait s)
                  (semaphore-post ready)
                  (sync t done)
                  (semaphore-post s))))
      (sync ready)
      (thunk)
      (semaphore-post done))))

(define (printf/flush fmt . args)
  (apply printf fmt args)
  (flush-output))

(define (start-vbox-vm vbox
                       #:max-vms [max-vm 1]
                       #:dry-run? [dry-run? #f]
                       #:log-status [log-status printf/flush]
                       #:pause-seconds [pause-seconds 3])
  (define (check-count)
    (define s (system*/string VBoxManage "list" "runningvms"))
    (unless ((length (string-split s "\n")) . < . max-vm)
      (error 'start-vbox "too many virtual machines running (>= ~a) to start: ~s"
             max-vm
             vbox)))
  (log-status "Starting VirtualBox machine ~s\n" vbox)
  (unless dry-run?
    (check-vbox-exe 'start-vbox-vm)
    (case (vbox-state vbox)
      [(running) (void)]
      [(paused) (vbox-control vbox "resume")]
      [(off saved) (call-with-vbox-lock
                    (lambda ()
                      (check-count)
                      (vbox-start vbox)))])
    (unless (eq? (vbox-state vbox) 'running)
      (error 'start-vbox-vm "could not get virtual machine started: ~s" vbox))
    ;; pause a little to let the VM get networking ready, etc.
    (sleep pause-seconds)))

(define (stop-vbox-vm vbox
                      #:save-state? [save-state? #t]
                      #:dry-run? [dry-run? #f]
                      #:log-status [log-status printf/flush])
  (log-status "Stopping VirtualBox machine ~s\n" vbox)
  (unless dry-run?
    (vbox-control vbox (if save-state? "savestate" "poweroff"))
    (unless (memq (vbox-state vbox) '(saved off))
      (error 'stop-vbox-vm "virtual machine isn't in the expected state: ~s" vbox))))

(define (take-vbox-snapshot vbox name)
  (check-vbox-exe 'take-vbox-snapshot)
  (unless (system* VBoxManage "snapshot" vbox "take" name)
    (error 'take-vbox-snapshot "failed")))

(define (restore-vbox-snapshot vbox name)
  (check-vbox-exe 'restore-vbox-snapshot)
  (unless (system* VBoxManage "snapshot" vbox "restore" name)
    (error 'restore-vbox-snapshot "failed")))

(define (delete-vbox-snapshot vbox name)
  (check-vbox-exe 'delete-vbox-snapshot)
  (unless (system* VBoxManage "snapshot" vbox "delete" name)
    (error 'delete-vbox-snapshot "failed")))

(define (exists-vbox-snapshot? vbox name)
  (check-vbox-exe 'exists-vbox-snapshot?)
  (define s (system*/string VBoxManage "snapshot" vbox "list" "--machinereadable"))
  (unless s
    (error 'exists-vbox-snapshot? "failed"))
  (regexp-match? (regexp (format "SnapshotName[-0-9]*=\"~a" (regexp-quote name)))
                 s))

(define (get-vbox-snapshot-uuid vbox name)
  (check-vbox-exe 'get-vbox-snapshot-uuid)
  (define s (system*/string VBoxManage "snapshot" vbox "list" "--machinereadable"))
  (unless s
    (error 'exists-vbox-snapshot? "failed"))
  (define rx (regexp (format "SnapshotName[-0-9]*=\"~a\"\nSnapshotUUID[-0-9]*=\"([^\"]*)\""
                             (regexp-quote name))))
  (define m (regexp-match rx s))
  (and m (cadr m)))

(define (import-vbox-vm path
                        #:name [name #f]
                        #:cpus [cpus #f]
                        #:memory [memory #f])
  (check-vbox-exe 'import-vbox-vm)
  (define args
    (for/fold ([args null])
              ([arg (in-list '(name cpus memory))]
               [val (in-list (list name cpus memory))]
               #:when val)
      (case arg
        [(cpus)   (list* "--vsys" "0" "--cpus" (number->string cpus) args)]
        [(name)   (list* "--vsys" "0" "--vmname" name args)]
        [(memory) (list* "--vsys" "0" "--memory" (number->string memory) args)])))

  (unless (apply system* VBoxManage "import" path args)
    (error 'import-vbox-vm "failed")))
