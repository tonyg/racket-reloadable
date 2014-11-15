# Code-reloading for Racket

Racket's built-in `dynamic-rerequire` does the heavy lifting, but
doesn't give a high-level interface to help us build reloadable
servers. This package fills in that gap.

## Example

A complete example of a website written using the
[Racket web-server](http://docs.racket-lang.org/web-server/) is
available at <https://github.com/tonyg/racket-reloadable-example>.

 - [`main.rkt`](https://github.com/tonyg/racket-reloadable-example/blob/master/src/main.rkt)
   is the permanent part of the server
 - [`site.rkt`](https://github.com/tonyg/racket-reloadable-example/blob/master/src/main.rkt)
   is the reloadable part of the server

## Usage

1. Split your server into a *permanent* and a *reloadable* part
2. Decide which pieces of state in the reloadable part should be *persistent*
3. Use indirection to access the reloadable part from the permanent part
4. Decide how and when to reload code

### Splitting the server

It's easiest to make the permanent part of your program as small as
possible. This is because if a module is `require`d by the permanent
part of your program, directly or indirectly, then it will *never* be
reloaded, even if it is also `require`d by the reloadable part.

Any modules `require`d from the permanent part of your program are
effectively included in the permanent part of the program.

For example, say your program is started from `main.rkt`, which will
be the permanent part of the application, with the bulk of the program
functionality in the reloadable part, `features.rkt`. Then your
`main.rkt` should be something along the lines of the following:

```racket
#lang racket
(require reloadable)
(define main (reloadable-entry-point->procedure
              (make-reloadable-entry-point 'start-program "features.rkt")))
(reload!)
(main)
```

where `start-program` is `provide`d from `features.rkt`. It is
important that we do not require `features.rkt` from `main.rkt`!
Instead, that is taken care of by the entry-point machinery in this
package.

You must call `reload!` at least once before accessing a new
entry-point's value.

You must also ensure that there are no stray `.zo` files for the
reloadable part of your program. If any such `.zo` files exist, they
will interfere with code loading.

### Persistent state

Your `features.rkt` module may have global variables. Some of these
should be initialised every time the module is reloaded, but others
should only be initialised once, at server startup time.

Global variables that should be reinitialised on every code reload do
not need to be declared differently:

```racket
(define module-variable-initialised-every-time
  (begin (printf "Reinitialising module-variable-initialised-every-time!\n")
         17))
```

Global variables that should be initialised only *once*, at server
startup, should be declared using `make-persistent-state`:

```racket
(define some-persistent-variable
  (make-persistent-state 'some-persistent-variable
                         (lambda ()
                           (printf "Initialising some-persistent-variable!\n")
                           42)))
```

Note that the first argument to `make-persistent-state` must be unique
across the entire Racket instance. This is arguably a bug: ideally,
it'd only need to be unique to a particular module. A future version
of this library may fix this.

Read and write persistent state values like you would parameters:

```racket
;; Access it
(printf "Current some-persistent-variable value: ~a"
        (some-persistent-variable))
;; Set it to a new value
(some-persistent-variable (compute-new-value))
```

### Accessing reloadable code from permanent code

Use the entry points you create with `make-reloadable-entry-point`
(which you may also retrieve after they are created by calling
`lookup-reloadable-entry-point`).

Each time `reload!` is called, the `reloadable-entry-point-value` of
each entry point is recomputed from the new versions of each module.

  - If an entry point holds a procedure, you can
	- extract its value and call it directly, or
	- use `reloadable-entry-point->procedure` to convert an entry-point
	  into a general procedure that reflects the calling conventions of
	  the underlying procedure.

  - If an entry point holds any other kind of value, you can use
    `reloadable-entry-point-value` to access it.

### Controlling code reloading

Direct calls to `reload!` force immediate reloading of any changed
code, subject to the caveats about the split between the permanent and
reloadable parts of your program given above.

In addition, by default, the reloadable part of your program is
scanned constantly for changes, and whenever the system notices that a
`.rkt` file in the reloadable part of your program has changed, it
will automatically be recompiled and reloaded.

To disable this automatic scanning, call

```racket
(set-reload-poll-interval! #f)
```

If automatic scanning is disabled, then calls to `reload!` will be the
only way to make code reloading happen.
