#lang scribble/manual
@(require (for-label racket/base
                     racket/contract
                     racket/string
                     remote-shell/ssh
                     remote-shell/vbox))

@title{Remote Shells and Virtual Machines}

The @filepath{remote-shell} collection provides tools for running
shell commands on a remote or virtual machine, including tools for
starting, stopping, and managing Docker containers and VirtualBox
virtual-machine instances.

@table-of-contents[]

@; ----------------------------------------

@section{Remote Shells}

@defmodule[remote-shell/ssh]

@defproc[(remote? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a remote-host representation
produced by @racket[remote], @racket[#f] otherwise.}

@defproc[(remote [#:host host string?]
                 [#:kind kind (or/c 'ip 'docker) 'ip]
                 [#:user user string? ""]
                 [#:shell shell (listof string?) '("/bin/sh" "-c")]
                 [#:env env (listof (cons/c string? string?)) '()]
                 [#:remote-tunnels remote-tunnels (listof (cons/c (integer-in 1 65535)
                                                                  (integer-in 1 65535)))
                                   null]
                 [#:key key (or/c #f path-string?) #f]
                 [#:timeout timeout-secs real? 600])
         remote?]{

Creates a representation of a remote host. The @racket[host] argument
specifies the host for an @exec{ssh} connection or a Docker container
name, depending on whether @racket[kind] is @racket['ip] or
@racket['docker]. The @racket[user] argument is only used for
@racket['ip] hosts; if @racket[user] is empty, then the current user
name is used for the remote host.

The @racket[shell] argument specifies the command and arguments that
are used to prefix a shell string to execute it on the remote host via
@racket[ssh].

The @racket[env] argument specifies environment variables to set
before running any command on the remote host.

The @racket[remote-tunnels] argument specifies ports to tunnel from
the remote host back to the local host; it must be @racket['()] for a
@racket['docker] host. The first port number in each pair is the port
number on the remote host, and the second port number is the port that
it tunnels to on the local host.

If @racket[key] is not @racket[#f], then it is used as the path to an identity
file used for public-key authentication for a @racket['ip] host/

The @racket[timeout] argument specifies a timeout after which a remote
command will be considered failed.

@history[#:changed "1.3" @elem{Added support for Docker containers, the @racket[kind]
                               argument, and the @racket[shell] argument.}]}


@defproc[(ssh [remote remote?]
              [command any/c] ...
              [#:mode mode (or/c 'error 'result 'output) 'error]
              [#:failure-log failure-dest (or/c #f path-string?) #f]
              [#:success-log success-dest (or/c #f path-string?) #f]
              [#:show-time? show-time? any/c #f])
           (or/c void? boolean? (cons/c boolean? bytes?))]{

Runs a shell command at @racket[remote], were the @racket[command]s
are converted to a string via @racket[display]
and concatenated (with no additional spaces) to specify the remote
shell command.

The implementation of the remote command depends on @racket[remote]:
@;
@itemlist[

 @item{If @racket[remote]'s kind is @racket['ip] and its host is
       @racket["localhost"], then @racket[remote]'s shell command is
       used directly.}

 @item{Otherwise, if @racket[remote]'s kind is @racket['ip], then the
       remote command is run by @exec{ssh} as found by
       @racket[find-system-path].}

 @item{If @racket[remote]'s kind is @racket['docker], then the remote
       command is run by @exec{docker exec} using @exec{docker} as
       found by @racket[find-system-path]. The Docker container named
       by @racket[remote] must be started already.}

]

If @racket[mode] is @racket['error], then the result is
@racket[(void)] or an exception is raised if the remote command fails
with an connection error, an error exit code, or by timing out. If
@racket[mode] is @racket['result], then the result is @racket[#t] for
success or @racket[#f] for failure. If @racket[mode] is
@racket['output], then the result is a pair containing whether the
command succeeded and a byte string for the command's output
(including error output).

If @racket[failure-dest] is not @racket[#f], then if the command
fails, the remote output (including error output) is recorded to the
specified file. If @racket[success-dest] is not @racket[#f], then if
the command fails, the remote output (including error output) is
recorded to the specified file.}

@defproc[(scp [remote remote?]
              [source path-string?]
              [dest path-string?]
              [#:mode mode (or/c 'error 'result 'output) 'error])
          (or/c void? boolean?)]{

Copies a file to/from a remote host. Use @racket[at-remote] to form
either the @racket[source] or @racket[dest] argument.

The remote copy is implemented with @exec{scp} as found by
@racket[find-system-path] if @racket[remote]'s kind is @racket['ip],
and it is implemented with @exec{docker cp} using @exec{docker} as
found by @racket[find-system-path] if @racket[remote]'s kind is
@racket['docker].

If @racket[mode] is @racket['error], then the result is
@racket[(void)] or an exception is raised if the remote command
fails. If @racket[mode] is @racket['result], then the result is
@racket[#t] for success or @racket[#f] for failure.}


@defproc[(at-remote [remote remote?]
                    [path path-string?])
         string?]{

Combines @racket[remote] and @racket[path] to form an argument for
@racket[scp] to specify a path at the remote host.}


@defproc[(make-sure-remote-is-ready [remote remote?]
                                    [#:tries tries exact-nonnegative-integer? 3])
         void?]{

Runs a simple command at @racket[remote] to check that it receives
connections, trying up to @racket[tries] times.}

@defproc[(remote-host [remote remote?]) string?]{
  Gets the hostname that the remote is set to use in string form.

@history[#:added "1.2"]}

@defboolparam[current-ssh-verbose on?]{

A parameter that determines whether @racket[ssh] echos its command to
@racket[(currrent-output-port)].

@history[#:added "1.3"]}

@; ----------------------------------------

@section{Managing Docker Containers and Images}

@defmodule[remote-shell/docker]{The
@racketmodname[remote-shell/docker] library provides support for
working with @hyperlink["https://www.docker.com/"]{Docker} images and
containers. The library is a fairly thin wrapper on the @exec{docker}
command, which is located via @racket[find-executable-path].}

@history[#:added "1.3"]

@defproc[(docker-build [#:name name string?]
                       [#:content content path-string?]
                       [#:platform platform (or/c string?) #f])
         void?]{

Builds a new Docker image tagged by @racket[name], using the
@racket[content] directory to create the image. The @racket[content]
directory should contain a file named @filepath{Dockerfile}. The optional
platform argument can select a platform different than the host default,
when supported by the host Docker installation, such as using
@racket["linux/amd64"] on AArch64 Mac OS.

@history[#:changed "1.7" @elem{Added the @racket[#:platform] argument.}]}

@defproc[(docker-image-id [#:name name string?])
         (or/c #f string?)]{

Returns the identity of a Docker image tagged by @racket[name],
returning @racket[#f] if no such image exists.}

@defproc[(docker-image-remove [#:name name string?])
         void?]{

Removes the Docker image indicated by @racket[name] (or, at least,
removes the tagged reference, but the image may persist if it has
other names).}


@defproc[(docker-create [#:name name string?]
                        [#:image-name image-name string?]
                        [#:platform platform (or/c #f string?) #f]
                        [#:network network (or/c #f string?) #f]
                        [#:volumes volumes (listof (list/c path-string? string? (or/c 'ro 'rw))) '()]
                        [#:memory-mb memory-mb (or/c #f exact-positive-integer?) #f]
                        [#:swap-mb swap-mb (or/c #f exact-positive-integer?) #f]
                        [#:replace? replace? boolean? #f])
         string?]{

Creates a Docker container as @racket[name] as an instance of
@racket[image-name]. If @racket[replace?] is true, then any existing
container using the name is stopped (if running) and removed, first.
The newly created container is not running.

If @racket[platform] is a string, then the created container uses that
platform. Specifying a platform is useful when a host can run multiple
platforms and @racket[image-name] is also available for multiple
platforms.

If @racket[network] is a string, then the created container uses that
network.

The @racket[volumes] argument supplies a mapping of host directories
to container directory paths, where the path on the container maps to
the host directory in the indicated mode: @racket['ro] for read-only
or @racket['rw] for read--write.

The @racket[memory-mb] and @racket[swap-mb] arguments determine the
amount of memory that the container can use in megabytes (MB), where
@racket[memory-mb] is ``real'' memory and @racket[swap-mb] is
additional swap space. If only one of the numbers is provided, the
default for the other is the same (i.e., by default, the total amount
of memory available including swap space is twice the provided value).
If neither is provided as a number, no specific limit is imposed on
the container.

@history[#:changed "1.5" @elem{Added @racket[#:memory-mb] and @racket[#:swap-mb].}
         #:changed "1.6" @elem{Added @racket[#:platform].}]}


@defproc[(docker-id [#:name name string?])
         (or/c #f string?)]{

Returns the identity of a Docker container @racket[name], returning
@racket[#f] if no such container exists.}

@defproc[(docker-running? [#:name name string?])
         boolean?]{

Determines whether the Docker container @racket[name] (which must
exist) is currently running.}

@defproc[(docker-remove [#:name name string?])
         void?]{

Removes the Docker container @racket[name], which must exist and must
not be running.}

@defproc[(docker-start [#:name name string?])
         void?]{

Starts the Docker container @racket[name], which must exist and must
not be running.}

@defproc[(docker-stop [#:name name string?])
         void?]{

Stops the Docker container @racket[name], which must exist and must be
running.}

@defproc[(docker-exec [#:name name string?]
                      [command path-string?]
                      [arg path-string?] ...
                      [#:mode mode (or/c 'error 'result) 'error])
         (or/c boolean? void?)]{

Executes @racket[command] with @racket[arg]s on the Docker container
@racket[name], which must exist and be running.

The @racket[mode] argument determines how failure of the command is
handled---either because the command exits with failure on the
container or due to a problem accessing the container---as well as the
return value for success. The @racket['error] mode raises an exception
for failure and returns @racket[(void)] for success, while
@racket['result] mode returns a boolean indicating whether the command
was successful.}

@defproc[(docker-copy [#:name name string?]
                      [#:src src path-string?]
                      [#:dest dest path-string?]
                      [#:mode mode (or/c 'error 'result) 'error])
         (or/c boolean? void?)]{

Copies a file to or from the Docker container @racket[name]. One of
@racket[src] or @racket[dest] should refer to a file on the host
machine, and the other should be a string prefixed with the
@racket[name] and @racket[":"] to indicate a path on the container.

The @racket[mode] argument determines how failure of the copy is
handled---either due to path problems or a problem accessing the
container---as well as the return value for success. The
@racket['error] mode raises an exception for failure and returns
@racket[(void)] for success, while @racket['result] mode returns a
boolean indicating whether the copy was successful.}

@; ----------------------------------------

@section{Managing VirtualBox Machines}

@defmodule[remote-shell/vbox]{The @racketmodname[remote-shell/vbox]
library provides support for working with
@hyperlink["https://www.virtualbox.org/"]{VirtualBox} instances. The
library is a fairly thin wrapper on the @exec{VBoxManage} command,
which is located via @racket[find-executable-path].}

@defproc[(start-vbox-vm [name string?]
                        [#:max-vms max-vms real? 1]
                        [#:log-status log-status (string? #:rest any/c . -> . any) printf]
                        [#:pause-seconds pause-seconds real? 3]
                        [#:dry-run? dry-run? any/c #f])
          void?]{

Starts a VirtualBox virtual machine @racket[name] that is in a saved,
powered off, or running state (where a running machine continues to
run).

The start will fail if @racket[max-vms] virtual machines are already
currently running. This limit is a precaution against starting too
many virtual-machine instances, which can overwhelm the host operating
system.

The @racket[log-status] argument is used to report actions and status
information.

After the machine is started, @racket[start-vbox-vm] pauses for the
amount of time specified by @racket[pause-seconds], which gives the
virtual machine time to find its bearings.

If @racket[dry-run] is @racket[#t], then the machine is not actually
started, but status information is written using @racket[log-status]
to report the action that would have been taken.}


@defproc[(stop-vbox-vm [name string?]
                       [#:save-state? save-state? any/c #t]
                       [#:log-status log-status (string? #:rest any/c . -> . any) printf]
                       [#:dry-run? dry-run? any/c #f])
         void?]{

Stops a VirtualBox virtual machine @racket[name] that is in a running
state. If @racket[save-state?] is true, then the machine is put into
saved state, otherwise the current machine state is discarded and the
machine is powered off.

The @racket[log-status] argument is used to report actions and status
information.

If @racket[dry-run] is @racket[#t], then the machine is not actually
started, but status information is written using @racket[log-status]
to report the action that would have been taken.}


@defproc[(take-vbox-snapshot [name string?]
                             [snapshot-name string?])
         void?]{

Takes a snapshot of a virtual machine (which may be running), creating
the snapshot named @racket[snapshot-name].}


@defproc[(restore-vbox-snapshot [name string?]
                                [snapshot-name string?])
         void?]{

Changes the current state of a virtual machine to be the one recorded
as @racket[snapshot-name]. The virtual machine must not be running.}

@defproc[(delete-vbox-snapshot [name string?]
                               [snapshot-name string?])
         void?]{

Deletes @racket[snapshot-name] for the virtual machine @racket[name].}


@defproc[(exists-vbox-snapshot? [name string?]
                                [snapshot-name string?])
         boolean?]{

Reports whether @racket[snapshot-name] exists for the virtual machine
@racket[name].}


@defproc[(get-vbox-snapshot-uuid [name string?]
                                 [snapshot-name string?])
         (or/c #f string?)]{

Returns the UUID of @racket[snapshot-name] for the virtual machine
@racket[name].

@history[#:added "1.1"]}

@defproc[(import-vbox-vm [path path-string?]
                         [#:name name (or/c false/c non-empty-string?) #f]
                         [#:cpus cpus (or/c false/c exact-positive-integer?) #f]
                         [#:memory memory (or/c false/c exact-positive-integer?) #f]) void?]{

Imports a VirtualBox VM from the OVF file at @racket[path].

When provided, @racket[name] specifies what the VM's alias (as seen in
the GUI and in the output of commands like @exec{VBoxManage list vms})
ought to be.

The @racket[cpus] argument can be used to override the number of
processors the VM has access to.

The @racket[memory] argument can be used to override the amount of RAM
(in MB) the VM has access to.

@history[#:added "1.4"]}
