;;; secretary.el --- Virtual assistant parts box -*- lexical-binding: t; -*-

;; Copyright (C) 2020-2021 Martin Edström

;; Author: Martin Edström <meedstrom@teknik.io>
;; URL: https://github.com/meedstrom/secretary
;; Version: 0.1.0
;; Created: 2020-12-03
;; Keywords: convenience
;; Package-Requires: ((emacs "27.1") (ts "0.3-pre") (s "1.12") (dash "2.19") (f "0.20.0") (ess "18.10.2") (pfuture "1.9") (named-timer "0.1") (transient "0.3.6"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; See README.org, info node (secretary) or website:
;; https://github.com/meedstrom/secretary

;;; Code:

;; builtins
(require 'seq)
(require 'map)
(require 'subr-x)
(require 'cl-lib)
(require 'find-func) ;; find-library-name
(require 'transient) ;; Emacs 28 builtin

;; external
(require 'ts) ;; essential
(require 'named-timer) ;; essential
(require 'ess) ;; TODO: Drop this
(require 'dash)
(require 's)
(require 'f) ;; f-read and f-append are just nice
(require 'pfuture)

;; Calm down the byte compiler
(declare-function calendar-check-holidays "holidays")
(declare-function calendar-current-date "calendar")
(declare-function run-ess-r "ess")
(declare-function ess-execute "ess")
(declare-function eww-current-url "eww")
(declare-function notifications-notify "notifications")
(declare-function org-mac-idle-seconds "org-clock")
(declare-function org-read-date "org")
(defvar exwm-class-name)
(defvar exwm-title)


;;; Some user options

(defgroup secretary nil "The Emacs in-house secretary."
  :prefix "secretary-"
  :group 'convenience)

(defcustom secretary-ai-name "Alfred"
  "Your secretary's name."
  :group 'secretary
  :type 'string
  :risky t)

(defcustom secretary-user-birthday nil
  "Your birthday, an YYYY-MM-DD string."
  :group 'secretary
  :type 'string
  :safe t)

(defcustom secretary-user-name
  (if (s-blank? user-full-name)
      "Mr. Bond"
    (-first-item (s-split " " user-full-name)))
  "Name by which you prefer the secretary to address you."
  :group 'secretary
  :type 'string
  :safe t)

(defcustom secretary-user-short-title "master"
  "A short title for you that works on its own, in lowercase."
  :group 'secretary
  :type 'string
  :safe t)

(defcustom secretary-sit-long 1
  "Duration in seconds to pause for effect.
See also `secretary-sit-medium' and `secretary-sit-short'."
  :group 'secretary
  :type 'float
  :safe t)

(defcustom secretary-sit-medium .8
  "Duration in seconds to pause for effect.
See also `secretary-sit-long' and `secretary-sit-short'."
  :group 'secretary
  :type 'float
  :safe t)

(defcustom secretary-sit-short .5
  "Duration in seconds to pause for effect.
See also `secretary-sit-long' and `secretary-sit-medium'."
  :group 'secretary
  :type 'float
  :safe t)

(defcustom secretary-presumptive nil
  "Whether to skip some prompts and assume yes."
  :group 'secretary
  :type 'boolean)

(defcustom secretary-cache-dir-path
  (expand-file-name "secretary" user-emacs-directory)
  "Directory for persistent files (not user datasets)."
  :group 'secretary
  :type 'directory
  :risky t)


;;; Library

(defvar secretary--current-fn nil)

(defvar secretary--queue nil)

(defvar secretary--buffer-r nil)

(defvar secretary-debug init-file-debug)

(defvar secretary-date (ts-now)
  "Date to which to apply the current fn.
Can be set anytime during a welcome to override the date to which
some queries apply, for example to log something for yesterday.
This may not apply, check the source for the welcomer you are
using.")

(defmacro secretary--process-output-to-string (program &rest args)
  "Like `shell-command-to-string' without the shell intermediary.
You don't need a /bin/sh.  PROGRAM and ARGS are passed on to
`call-process'."
  (declare (debug (&rest form)))
  `(with-temp-buffer
     (call-process ,program nil (current-buffer) nil ,@args)
     (buffer-string)))

(defmacro secretary--process-output-to-number (program &rest args)
  "Like `shell-command-to-string' without the shell intermediary.
Also converts the result to number. PROGRAM and ARGS are passed
on to `call-process'."
  (declare (debug (&rest form)))
  `(string-to-number (secretary--process-output-to-string ,program ,@args)))

(defun secretary--init-r ()
  "Spin up an R process and load needed R libraries.
Uses `run-ess-r' which is full of sanity checks (e.g. for cygwin
and text encoding), but creates an interactive R buffer which
unfortunately may surprise the user when they go to work on their
own R project."
  (let ((default-directory (f-dirname (find-library-name "secretary"))))
    (save-window-excursion
      (setq secretary--buffer-r (run-ess-r)))
    ;; gotcha: only use `ess-with-current-buffer' for temp output buffers, not
    ;; for the process buffer
    (with-current-buffer secretary--buffer-r
      ;; TODO: How to check if the script errors out?
      (ess-execute "source(\"make_data_for_plots.R\")" 'buffer))))

;; TODO: Catch typos like 03 meaning 30 minutes, not 3 hours.
(defun secretary-parse-time-amount (input)
  "Translate INPUT from hours or minutes into minutes.
If INPUT contains no \"h\" or \"m\", assume numbers above 20 are
minutes and numbers below are hours."
  (declare (pure t) (side-effect-free t))
  (let ((numeric-part (string-to-number input)))
    (cond ((= 0 numeric-part) ;; strings without any number result in 0
           nil) ;; save as a NA observation
          ((and (string-match-p "h.*m" input) (> numeric-part 0))
           (warn "I'm not sophisticated enough to parse that"))
          ((string-match-p "h" input)
           (* 60 numeric-part))
          ((string-match-p "m" input)
           numeric-part)
          ((-> numeric-part (>= 20))
           numeric-part)
          (t
           (* 60 numeric-part)))))

(defun secretary-coerce-to-hh-mm (input)
  "Coerce from INPUT matching HH:MM, HH or H, to HH:MM (24-h).
If \"am\" or \"pm\" present, assume input is in 12-hour clock."
  (declare (pure t) (side-effect-free t))
  (unless (s-matches-p (rx num) input)
    (error "%s" (concat "Invalid time: " input)))
  (let* ((hhmm (or (cdr (s-match (rx (group (= 2 num)) punct (group (= 2 num)))
                                 input))
                   (cdr (s-match (rx (group (= 1 num)) punct (group (= 2 num)))
                                 input))
                   (s-match (rx (= 2 num)) input)
                   (s-match (rx (= 1 num)) input)))
         (hour (string-to-number (car hhmm)))
         (minute (string-to-number (or (cadr hhmm) "00"))))
    (when (or (> hour 24)
              (and (> hour 12)
                   (s-matches-p (rx (or "pm" "am")) input)))
      (error "%s" (concat "Invalid time: " input)))
    (when (and (s-contains-p "pm" input)
               (/= 12 hour))
      (cl-incf hour 12))
    (when (and (s-contains-p "am" input)
               (= 12 hour))
      (setq hour 0))
    (when (= 24 hour)
      (setq hour 23)
      (setq minute 59))
    (concat (when (< hour 10) "0")
            (number-to-string hour) ":"
            (when (< minute 10) "0")
            (number-to-string minute))))


;;; Library for interactivity

(defcustom secretary-chat-log-path
  (convert-standard-filename
   (expand-file-name "chat.log" secretary-cache-dir-path))
  "Where to save chat log across sessions. Can be nil."
  :group 'secretary
  :type 'file
  :safe t)

(defvar secretary--midprompt-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C--") #'secretary-decrement-date)
    (define-key map (kbd "C-+") #'secretary-increment-date)
    (define-key map (kbd "C-0") #'secretary-set-date-today)))

(defvar secretary--just-typed-k nil)

;; TODO: test nil initvalue
(defvar secretary--last-chatted
  (make-ts :unix 0)
  "Timestamp updated whenever the chat is written to.")

(defun secretary--buffer-chat ()
  "Buffer where the secretary sends its messages."
  (or (get-buffer (concat "*" secretary-ai-name ": chat log*"))
      (let ((buf (get-buffer-create
                  (concat "*" secretary-ai-name ": chat log*"))))
        (with-current-buffer buf
          (secretary-chat-mode)
          (setq-local auto-save-visited-mode nil)
          (setq-local require-final-newline nil)
          (buffer-disable-undo)
          ;;(whitespace-cleanup)
          (visual-line-mode)
          (and secretary-chat-log-path
               (file-exists-p secretary-chat-log-path)
               (insert-file-contents secretary-chat-log-path))
          (setq-local buffer-read-only t))
        buf)))

(defun secretary--y-or-n-p-insert-k ()
  "Mostly like `y-or-n-p-insert-y'."
  (interactive nil minibuffer-mode)
  (delete-minibuffer-contents)
  (insert "y")
  (setq secretary--just-typed-k t)
  (exit-minibuffer))

(defun secretary-ynp (&rest strings)
  "Wrapper around `y-or-n-p'.
Concatenates STRINGS into one prompt, prints it to the chat
buffer, binds certain hotkeys."
  (let* (;; (default-y-or-n-p-map y-or-n-p-map)
         ;; (default-cmd (lookup-key y-or-n-p-map (kbd "k")))
         ;; TODO: Also show which log file we're applying to
         (background-info (concat "[Applying to date: "
                                  (ts-format "%Y %b %d" secretary-date)
                                  "]\n"))
         (prompt (string-join strings)))
    (unwind-protect
        (progn
          (pop-to-buffer (secretary--buffer-chat))
          (secretary-emit prompt)
          (define-key y-or-n-p-map (kbd "h") #'secretary-dispatch)
          (define-key y-or-n-p-map (kbd "<SPC>") #'secretary-dispatch)
          (define-key y-or-n-p-map (kbd "k") #'secretary--y-or-n-p-insert-k)
          (setq-local buffer-read-only nil)
          (let ((result (y-or-n-p (concat background-info prompt))))
            (with-silent-modifications
              (if secretary--just-typed-k
                  (progn
                    (setq secretary--just-typed-k nil)
                    (secretary-emit-same-line " Okay..."))
                (if result
                    (secretary-emit-same-line " Yes.")
                  (secretary-emit-same-line " No."))))
            result))
      (setq-local buffer-read-only t)
      (dolist (x '("o" "i" "k" "<SPC>"))
        (define-key y-or-n-p-map (kbd x) #'y-or-n-p-insert-other)))))

(defun secretary-check-special-input (input)
  "Check INPUT for keywords like \"/skip\" and react specially."
  (cond ((string-match-p "/skip" input)
         (if (and (< 1 (length secretary--queue))
                  (member secretary--current-fn secretary--queue))
             ;; Try to proceed to next item
             (progn
               (setq secretary--queue
                     (cl-remove secretary--current-fn secretary--queue
                                :count 1))
               (secretary-resume))
           ;; Just cancel the session
           (abort-recursive-edit)))
        ((string-match-p "help" input)
         (secretary-dispatch) ;; TODO: develop a midprompt-dispatch
         (abort-recursive-edit))))

(defun secretary-read (prompt &optional collection default)
  "Wrapper for `completing-read'.
PROMPT, COLLECTION and DEFAULT are as in that function.

Echo both prompts and responses to the chat buffer, prepend
metadata to PROMPT, check for special keyword input, etc."
  (secretary-emit prompt)
  (set-transient-map secretary--midprompt-keymap #'minibufferp)
  (let* ((background-info (concat "[Applying to date: "
                                  (ts-format "%Y %b %d" secretary-date)
                                  "]\n"))
         (extra-collection '("/skip" "/help"))
         (input (completing-read
                 (concat background-info
                         (ts-format "<%H:%M> ")
                         prompt
                         (when (stringp default)
                           " (default " default "): "))
                 (append collection extra-collection)
                 nil nil nil nil
                 (when (stringp default)
                   default))))
    (secretary-emit-same-line input)
    (secretary-check-special-input input)
    input))

(defun secretary-read-string
    (prompt &optional initial-input history default-value)
  "Like `secretary-read' but call `read-string' internally.
All of PROMPT, INITIAL-INPUT, HISTORY, DEFAULT-VALUE are passed
to that function, though PROMPT is prepended with extra info."
  (secretary-emit prompt)
  (let* ((background-info (concat "[Applying to date: "
                                  (ts-format "%Y %b %d" secretary-date) "]\n"))
         (input (read-string
                 (concat background-info
                         (ts-format "<%H:%M> ")
                         prompt)
                 initial-input
                 history
                 default-value)))
    (secretary-emit-same-line input)
    (secretary-check-special-input input)
    input))

(defun secretary-emit (&rest strings)
  "Write a line to the chat buffer, made from STRINGS.
Returns the completed string so you can pass it to `message', for
example."
  (let ((new-date-maybe (if (/= (ts-day (ts-now))
                                (ts-day secretary--last-chatted))
                            (concat "\n\n"
                                    (ts-format "%A, %d %B %Y")
                                    (secretary--holiday-maybe)
                                    "\n")
                          ""))
        (msg (concat "\n<" (ts-format "%H:%M") "> " (string-join strings))))
    (with-current-buffer (secretary--buffer-chat)
      (goto-char (point-max))
      (with-silent-modifications
        (delete-blank-lines)
        (insert new-date-maybe)
        (insert msg))))
  (setq secretary--last-chatted (ts-now))
  (string-join strings))

(defun secretary-emit-same-line (&rest strings)
  "Print STRINGS to the chat buffer without newline."
  (let ((msg (string-join strings)))
    (with-current-buffer (secretary--buffer-chat)
      (goto-char (point-max))
      (with-silent-modifications
        (insert msg)))
    (setq secretary--last-chatted (ts-now))
    msg))


;;; Library for greeting messages

(defvar secretary-greetings
  '((concat "Welcome back, Master.")
    (concat "Nice to see you again, " secretary-user-name ".")
    (concat "Greetings, " secretary-user-name "."))
  "Greeting phrases which can initiate a conversation.")

;; NOTE: I considered making external variables for morning, day and evening
;;       lists, but users might also want to change the daytime boundaries or
;;       even add new boundaries. Too many possibilities, this is a case where
;;       it's ok to make the user override the defun as a primary means of
;;       customization.
(defun secretary-daytime-appropriate-greetings ()
  "Return different greeting strings appropriate to daytime."
  (cond ((> 5 (ts-hour (ts-now)))
         (list "You're up late, Master."
               "Burning the midnight oil?"))
        ((> 10 (ts-hour (ts-now)))
         (list (concat "Good morning, " secretary-user-name ".")
               "Good morning!"
               "The stars shone upon us last night."))
        ((> 16 (ts-hour (ts-now)))
         (list "Good day!"))
        (t
         (list "Good evening!"
               "Pleasant evening to you!"))))

(defun secretary--holiday-maybe ()
  "If today's a holiday, format a suitable string."
  (declare (side-effect-free t))
  (require 'calendar)
  (require 'holidays)
  (if-let (foo (calendar-check-holidays (calendar-current-date)))
      (concat " -- " (s-join " " foo))
    ""))

(defun secretary-greeting-curt ()
  "Return a greeting appropriate in the midst of a workday.
Because if you've already exchanged good mornings, it's weird to
do so again."
  (seq-random-elt `("Hello" "Hi" "Hey")))

(defun secretary-greeting ()
  "Return a greeting string."
  (let ((bday (ts-parse secretary-user-birthday)))
    (cond ((equal (ts-format "%F" bday) (ts-format "%F" (ts-now)))
           (concat "Happy birthday, " secretary-user-name "."))
          ;; If it's morning, always use a variant of "good morning"
          ((> 10 (ts-hour (ts-now)) 5)
           (eval (seq-random-elt (secretary-daytime-appropriate-greetings))
                 t))
          (t
           (eval (seq-random-elt
                  (append secretary-greetings
                          (-list (secretary-daytime-appropriate-greetings))))
                 t)))))

(defun secretary-greeting-standalone ()
  "Return a greeting that expects to be followed by nothing.
No prompts, no debug message, no info. Suitable for
`notifications-notify' or `startup-echo-area-message'. A superset
of `secretary-greeting'. Mutually exclusive with
`secretary-greeting-curt'."
  (eval (seq-random-elt
         (append secretary-greetings
                 (-list (secretary-daytime-appropriate-greetings))
                 '("How may I help?")))))


;;; Library for chimes

(defcustom secretary-chime-sound-path
  (convert-standard-filename
   (expand-file-name
    ;; From https://freesound.org/people/josepharaoh99/sounds/380482/
    "assets/Chime Notification-380482.wav"
    ;; From https://bigsoundbank.com/detail-0319-knock-on-a-glass-door-1.html
    ;; "assets/DOORKnck_Knock on a glass door 1 (ID 0319)_BSB.wav"
    (f-dirname (find-library-name "secretary"))))
  "Sound to play when a welcomer is triggered unannounced."
  :group 'secretary
  :type 'file)

(defcustom secretary-play-sounds nil
  "Whether to play sounds."
  :group 'secretary
  :type 'boolean)

(defun secretary--chime-aural ()
  "Play a sound."
  (and secretary-play-sounds
       (executable-find "aplay")
       (file-exists-p secretary-chime-sound-path)
       (pfuture-new "aplay" secretary-chime-sound-path)))

(defun secretary--chime-visual ()
  "Give the fringes a flash of color and fade out."
  (let ((colors '((.1 . "green")
                  (.2 . "#aca")
                  (.3 . "#7a7")
                  (.4 . "#696")
                  (.5 . "#363"))))
    (let ((orig (face-background 'fringe)))
      (dolist (x colors)
        (run-with-timer (car x) nil
                        #'set-face-background 'fringe (cdr x)))
      (run-with-timer .6 nil #'set-face-background 'fringe orig))

    (when (facep 'solaire-fringe-face)
      (let ((orig (face-background 'solaire-fringe-face)))
        (dolist (x colors)
          (run-with-timer (car x) nil
                          #'set-face-background 'solaire-fringe-face (cdr x)))
        (run-with-timer .6 nil
                        #'set-face-background 'solaire-fringe-face orig)))
    nil))


;;; Library for files

(defun secretary--transact-buffer-onto-file (buffer path)
  "Append contents of BUFFER to file at PATH, emptying BUFFER."
  (mkdir (f-dirname path) t)
  (with-current-buffer buffer
    (whitespace-cleanup) ;; TODO dont use this (user may have customized)
    (secretary-append-safely (buffer-string) path)
    (delete-region (point-min) (point-max))))

(defun secretary--count-successes-today (fn)
  "Add up occurrences of timestamps for FN in related log files."
  (let ((dataset (secretary-item-dataset (secretary-item-by-fn fn)))
        (log (expand-file-name (concat "successes-" (symbol-name fn))
                               secretary-cache-dir-path)))
    (if (and dataset
             (f-exists-p dataset))
        (length (secretary-tsv-entries-by-date dataset))
      ;; FIXME: this has only unixstamps, get-entries scans for datestamps, so
      ;; this will always be zero
      (if (f-exists-p log)
          (length (secretary-tsv-entries-by-date log))
        (message "No dataset or log file found for %s %s."
                 (symbol-name fn)
                 "(may simply not exist yet)")
        0))))

(defun secretary-write-safely (text path)
  "Write TEXT to file at PATH if the content differs.
Also revert any buffer visiting it, or signal an error if there
are unsaved changes."
  (let ((buf (find-buffer-visiting path)))
    (and buf
         (buffer-modified-p buf)
         (error "Unsaved changes in open buffer: %s" (buffer-name buf)))
    (unless (and (f-exists-p path)
                 (string= text (f-read path 'utf-8)))
      (f-write text 'utf-8 path)
      (and buf (with-current-buffer buf
                 (revert-buffer))))))

(defun secretary-append-safely (text path)
  "Append TEXT to file at PATH.
Also revert any buffer visiting it, or warn if there are unsaved
changes and append to a file named PATH_errors."
  (let ((buf (find-buffer-visiting path))
        (errors-path (concat path "_errors")))
    (and buf
         (buffer-modified-p buf)
         (warn "Unsaved changes in open buffer: %s, writing to %s"
               (buffer-name buf) errors-path)
         (f-append text 'utf-8 errors-path))
    (unless (= 0 (length text)) ;; no unnecessary disk writes
      (f-append text 'utf-8 path)
      (and buf (with-current-buffer buf
                 (revert-buffer))))))

;; NOTE: Actually unused in this package, but may be useful.
;; WONTFIX: check for recent activity (user awake thru the night) and keep
;;          returning t
(defun secretary-logged-today-p (path)
  "True if file at PATH contains any reference to today.
Does this by searching for a YYYY-MM-DD datestamp."
  (when (file-exists-p path)
    ;; don't act like it's a new day if the time is <5am.
    (let ((day (if (> 5 (ts-hour (ts-now)))
                   (ts-dec 'day 1 (ts-now))
                 (ts-now))))
      (with-temp-buffer
        (insert-file-contents-literally path)
        (when (search-forward (ts-format "%F" day) nil t)
          t)))))

(defun secretary-first-today-line-in-file (path &optional ts)
  "In file at PATH, get the first line that refers to today.
Does this by searching for a YYYY-MM-DD datestamp matching today
or a ts object TS."
  (with-temp-buffer
    (insert-file-contents path)
    (search-forward (ts-format "%F" ts))
    (buffer-substring (line-beginning-position) (line-end-position))))

(defun secretary-last-datestamp-in-file (path)
  "Get the last match of YYYY-MM-DD in PATH.
Beware that if PATH has instances of such where you don't expect
it (in additional columns), you might not get the datestamp you
meant to get."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (goto-char (point-max))
    (re-search-backward (rx (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)))
    (buffer-substring (point) (+ 10 (point)))))

(defun secretary-tsv-all-entries (path)
  "Return the contents of a .tsv at PATH as a Lisp list."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (flush-lines (rx bol eol))
    (let ((rows (s-split "\n" (buffer-string) t)))
      (--map (s-split "\t" it) rows))))

;; HACK: strong assumption
(defun secretary-tsv-last-timestamp* (path)
  "In .tsv at PATH, get the second field of last row."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-max))
    (when (looking-back "^" nil) ;; if trailing newline
      (forward-line -1))
    (goto-char (line-beginning-position))
    (search-forward "\t")
    (buffer-substring (point) (- (search-forward "\t") 1))))

;; TODO: Search for unix-stamps too.
(defun secretary-tsv-entries-by-date (path &optional ts)
  "Return the contents of a .tsv at PATH as a Lisp list.
Filters for rows containing a YYYY-MM-DD datestamp matching today
or optional ts object TS."
  (if (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents-literally path)
        (let (x)
          (while (search-forward (ts-format "%F" ts) nil t)
            (push (split-string (buffer-substring (line-beginning-position)
                                                  (line-end-position))
                                "\t")
                  x)
            (goto-char (line-end-position)))
          x))
    (warn "File doesn't exist: %s" path)
    nil))

(defun secretary-tsv-last-row (path)
  "In .tsv at PATH, get last row as a Lisp list."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-max))
    (when (looking-back "^" nil) ;; if empty line
      (forward-line -1))
    (split-string (buffer-substring (line-beginning-position)
                                    (line-end-position))
                  "\t")))

(defun secretary-tsv-last-value (path)
  "In .tsv at PATH, get the value of last row, last field."
  (when (file-exists-p path)
    (with-temp-buffer
      (insert-file-contents-literally path)
      (goto-char (point-max))
      (search-backward "\t")
      (forward-char)
      (buffer-substring (point) (line-end-position)))))

(cl-defun secretary-tsv-append
    (path &rest fields &key float-time &allow-other-keys)
  "Append a line to the file located at PATH.
Create the file and its parent directories if it doesn't exist,
and make sure the line begins on a newline.  Treat each argument
in FIELDS... as a separate data field, inserting a tab character
in between, and warn if a field contains a tab character.

For database purposes (which you may not need), FIELDS is
prepended with a field for the Unix timestamp representing
\"posted time\" i.e. right now, the time the row was added.  If
time is also an actual variable you want to track, add a separate
field containing something like the output of `(ts-format
secretary-date)'.  The first field is not for that.  Optional
key FLOAT-TIME, if non-nil, means to use a float instead of
integer for the first field."
  (declare (indent defun))
  (unless (file-exists-p path)
    (make-empty-file path t))
  (let* ((fields (-replace nil "" fields))
         (newline-maybe (if (s-ends-with-p "\n" (f-read-bytes path))
                            ""
                          "\n"))
         ;; don't do a blank initial line on a new file
         (newline-maybe-really (if (string= "" (f-read-bytes path))
                                   ""
                                 newline-maybe))
         ;; On my machine at least, `ts-unix' and `float-time' very frequently
         ;; return numbers at a precision of 7 subsecond digits, ensure it for
         ;; consistent string lengths (aesthetic).
         ;;
         ;; TODO: Actually it sometimes (very rarely) hits 8, should we just
         ;; use the full %N?
         (posted (if float-time
                     (ts-format "%s.%7N")
                   (ts-format "%s")))
         (text (string-join fields "\t"))
         (new-text (concat newline-maybe-really posted "\t" text))
         (errors-path (concat path "_errors")))
    (cond
     ((--any-p (s-contains-p "\t" it) fields)
      (warn "Entry had tabs inside fields, wrote to %s" errors-path)
      (f-append new-text 'utf-8 errors-path)
      nil)
     ((s-contains-p "\n" text)
      (warn "Entry had newlines, wrote to %s" errors-path)
      (f-append new-text 'utf-8 errors-path)
      nil)
     (t
      (secretary-append-safely new-text path)
      t))))


;;; The big boilerplate

(defvar secretary-excursion-buffers nil
  "Buffers included in the current or last excursion.")

;; Ok, here's the shenanigans.  Observe that keyboard-quit and
;; abort-recursive-edit are distinct.  When the user cancels a "query" by
;; typing C-g, they were in the minibuffer, so it calls abort-recursive-edit.
;; You can define an "excursion" by putting a keyboard-quit in BODY.  With
;; this, we ensure different behavior for queries and excursions.  How?  We
;; advise abort-recursive-edit to do things that we only want when a query is
;; cancelled.  In this macro, pay attention to the placement of NEW-BODY, since
;; it may contain a keyboard-quit.  Thus, everything coming after NEW-BODY will
;; never be called for excursions, unless of course you use unwind-protect.
(defmacro secretary-defun (name args &rest body)
  "Boilerplate wrapper for `cl-defun'.
NAME, ARGS and BODY are as in `cl-defun'.
To see what it expands to, try `emacs-lisp-macroexpand'.

Manages the external variables `secretary--current-fn' and
`secretary--queue', zeroes `-item-dismissals' on success, advises
`abort-recursive-edit' (\\<selectrum-minibuffer-map> \\[abort-recursive-edit]) while in a prompt
spawned within BODY, and so on. If you use a simple `defun' in
lieu of this wrapper, you must replicate these features!

In BODY, you have access to the extra temporary variables:
- \"current-item\" which is \"(secretary-item-by-fn secretary--current-fn)\"
- \"current-dataset\" which is \"(secretary-item-dataset current-item)\"."
  (declare (indent defun) (doc-string 3))
  (let* ((parsed-body (macroexp-parse-body body))
          (declarations (car parsed-body))
          (new-body (cdr parsed-body)))
    `(cl-defun ,name ,args
       ;; Ensure it's always interactive
       ,@(if (member 'interactive (-map #'car-safe declarations))
           declarations
           (-snoc declarations '(interactive)))
       (setq secretary--current-fn #',name)
       (when (minibufferp)
         (warn "Was in minibuffer when %s called, not proceeding."
               (symbol-name secretary--current-fn))
         (keyboard-quit))
       (unless (get-buffer-window (secretary--buffer-chat))
         (pop-to-buffer (secretary--buffer-chat)))
       (unless (secretary-item-by-fn secretary--current-fn)
         (error "%s not listed in secretary-items" (symbol-name secretary--current-fn)))
       ;; Set up watchers in case any "excursion" happens.
       ;; (unless (called-interactively-p 'any) ;; allow manual use via M-x without triggering shenanigans
       (add-hook 'kill-buffer-hook #'secretary--check-return-from-excursion 96)
       (named-timer-run :secretary-excursion (* 5 60) nil #'secretary-stop-watching-excursion)
       ;; Set up watcher for cancelled prompt.
       (advice-add 'abort-recursive-edit :before #'secretary--after-cancel-do-things)
       (let* ((current-item (secretary-item-by-fn secretary--current-fn))
              (current-dataset (secretary-item-dataset current-item)))
         (unwind-protect
             (prog1 (progn
                      ;; I suppose we could infer from last-called afterwards
                      ;; whether the excursion was a failure?
                      (setf (secretary-item-last-called current-item)
                            (time-convert (current-time) 'integer))
                      ,@new-body)
               ;; All below this line will only happen for pure queries, and only after success.
               (setq secretary--queue
                     (cl-remove secretary--current-fn secretary--queue :count 1))
               (setf (secretary-item-dismissals current-item) 0)
               ;; Save timestamp of this successful run, even if there's no user-specified dataset.
               (when (null current-dataset)
                 (secretary-tsv-append
                   (expand-file-name ,(concat "successes-" (symbol-name name)) secretary-cache-dir-path)))
               ;; Clean up, because this wasn't an excursion.
               (named-timer-cancel :secretary-excursion)
               (remove-hook 'kill-buffer-hook #'secretary--check-return-from-excursion))
           ;; All below this line will happen for both queries and excursions, success or no.
           (advice-remove 'abort-recursive-edit #'secretary--after-cancel-do-things)
           ;; maybe the reason the variable's always nil
           ;; (when (called-interactively-p 'any)
             ;; (setq secretary-excursion-buffers nil))
           )))))

(defmacro secretary-defquery (name args &rest body)
  "Boilerplate wrapper for `cl-defun'.
To see what it expands to, visit secretary-tests.el and read the
tests of this macro.

Manages the external variables `secretary--current-fn' and
`secretary--queue', zeroes `-item-dismissals' on success, and
advises `abort-recursive-edit' (in common parlance C-g). If you
use a simple `defun' in lieu of this wrapper, you must replicate
these features!

In BODY, you have access to the extra temporary variable:
- \"current-dataset\" which is a reference to (secretary-item-dataset (secretary-item-by-fn secretary--current-fn))."
  (declare (indent defun) (doc-string 3))
  (let* ((parsed-body (macroexp-parse-body body))
         (declarations (car parsed-body))
         (new-body (cdr parsed-body)))
    `(cl-defun ,name ,args
       ;; Ensure it's always interactive
       ,@(if (member 'interactive (-map #'car-safe declarations))
             declarations
           (-snoc declarations '(interactive)))
       (setq secretary--current-fn #',name)
       (unless (secretary-item-by-fn secretary--current-fn)
         (error "%s not listed in secretary-items" (symbol-name secretary--current-fn)))
       (advice-add 'abort-recursive-edit :before #'secretary--after-cancel-do-things)
       (let ((current-dataset (secretary-item-dataset
                               (secretary-item-by-fn secretary--current-fn))))
         (unwind-protect
             (prog1 (progn
                      ,@new-body)
               (setq secretary--queue
                     (cl-remove secretary--current-fn secretary--queue :count 1))
               (setf (secretary-item-dismissals
                      (secretary-item-by-fn secretary--current-fn))
                     0)
               ;; TODO: actually, just increment a lisp variable, later synced
               ;;       to disk. Let's get around to having a big list instead of a
               ;;       separate var for each thing.
               ;; Save timestamp of this successful run.
               (when (null current-dataset)
                 (secretary-tsv-append
                   (expand-file-name ,(concat "successes-" (symbol-name name)) secretary-cache-dir-path))))
           (advice-remove 'abort-recursive-edit #'secretary--after-cancel-do-things))))))

(defun secretary--check-return-from-excursion ()
  "If the current excursion appears done, do things."
  (let ((others (remove (current-buffer) secretary-excursion-buffers)))
    (when (-none-p #'buffer-live-p others)
      (remove-hook 'kill-buffer-hook #'secretary--check-return-from-excursion)
      (named-timer-cancel :secretary-excursion)
      (setq secretary-excursion-buffers nil) ;; hygiene
      (when (null (secretary-item-dataset
                   (secretary-item-by-fn secretary--current-fn)))
        (secretary-tsv-append
          (expand-file-name (concat "successes-"
                                    (symbol-name secretary--current-fn))
                            secretary-cache-dir-path)))
      (setq secretary--queue
            (cl-remove secretary--current-fn secretary--queue :count 1))
      ;; HACK Because the current-buffer is still active, wait to be sure the
      ;; kill-buffer completes.  I would like an after-kill-buffer-hook so I
      ;; don't need this timer.
      (run-with-timer 0.25 nil #'secretary-resume))))

(defun secretary-stop-watching-excursion ()
  "Called after some time on an excursion."
  (named-timer-cancel :secretary-excursion)
  (remove-hook 'kill-buffer-hook #'secretary--check-return-from-excursion))

(defun secretary--after-cancel-do-things ()
  "Actions after user cancels a secretary prompt."
  (advice-remove 'abort-recursive-edit #'secretary--after-cancel-do-things)
  (cl-incf (secretary-item-dismissals
             (secretary-item-by-fn secretary--current-fn)))
  ;; Re-add the fn to the queue because it got removed (so I expect); after a
  ;; cancel, we want it to remain queued up.
  (cl-pushnew secretary--current-fn secretary--queue)
  (setq secretary--current-fn nil)) ;; hygiene

;; WIP
(defun secretary-body (&rest body)
  (unless (secretary-item-by-fn secretary--current-fn)
    (error "%s not listed in secretary-items" (symbol-name secretary--current-fn)))
  ;; Set up watchers in case any "excursion" happens.
  ;; (unless (called-interactively-p 'any) ;; allow manual use via M-x without triggering shenanigans
  (add-hook 'kill-buffer-hook #'secretary--check-return-from-excursion 96)
  (named-timer-run :secretary-excursion (* 5 60) nil #'secretary-stop-watching-excursion)
  ;; Set up watcher for cancelled prompt.
  (advice-add 'abort-recursive-edit :before #'secretary--after-cancel-do-things)
  (let* ((current-item (secretary-item-by-fn secretary--current-fn))
         (current-dataset (secretary-item-dataset current-item)))
    (unwind-protect
        (prog1 (progn
                 ;; I suppose we could infer from last-called afterwards
                 ;; whether the excursion was a failure?
                 (setf (secretary-item-last-called current-item)
                       (time-convert (current-time) 'integer))
                 (eval body t))
          ;; All below this line will only happen for pure queries, and only after success.
          (setq secretary--queue
                (cl-remove secretary--current-fn secretary--queue :count 1))
          (setf (secretary-item-dismissals current-item) 0)
          ;; Save timestamp of this successful run, even if there's no user-specified dataset.
          (when (null current-dataset)
            (secretary-tsv-append
              (expand-file-name (concat "successes-" (symbol-name secretary--current-fn)) secretary-cache-dir-path)))
          ;; Clean up, because this wasn't an excursion.
          (named-timer-cancel :secretary-excursion)
          (remove-hook 'kill-buffer-hook #'secretary--check-return-from-excursion))
      ;; All below this line will happen for both queries and excursions, success or no.
      (advice-remove 'abort-recursive-edit #'secretary--after-cancel-do-things))))


;;; Handle idle & reboots & crashes

(defcustom secretary-idle-log-path
  (convert-standard-filename "~/self-data/idle.tsv")
  "Location of the idleness log."
  :group 'secretary
  :type 'file)

(defcustom secretary-fallback-to-emacs-idle nil
  "Track Emacs idle rather than turn off under unknown OS/DE.
Not recommended, as the idleness log will be meaningless unless
you never use a graphical program. You'll end up with the
situation where returning to Emacs from a long Firefox session
triggers the return-from-idle-hook.

Even EXWM will not update `current-idle-time' while an X window
is in focus."
  :group 'secretary
  :type 'boolean)

(defcustom secretary-idle-threshold-secs-short (* 10 60)
  "Duration in seconds, above which the user is considered idle."
  :group 'secretary
  :type 'integer)

(defcustom secretary-idle-threshold-secs-long (* 90 60)
  "Be idle at least this many seconds to be greeted upon return."
  :group 'secretary
  :type 'integer)

(defcustom secretary-return-from-idle-hook
  '(secretary--log-idle
    secretary-session-from-idle)
  "Hook run when user returns from a period of idleness.
Note: An Emacs startup also counts as a return from idleness.
You'll probably want your hook to be conditional on some value of
`secretary-length-of-last-idle', which at startup is calculated
from the last Emacs shutdown or crash (technically, last time
the mode was enabled)."
  :group 'secretary
  :type '(hook :options (secretary--log-idle
                         secretary-session-from-idle)))

(defcustom secretary-periodic-present-hook
  '(secretary--save-vars-to-disk
    secretary--save-buffer-logs-to-disk)
  "Hook run periodically as long as the user is not idle.
Many things do not need to be done while the user is idle, so
think about whether your function does.  If not, put them here."
  :group 'secretary
  :type '(hook :options (secretary--save-vars-to-disk
                         secretary--save-buffer-logs-to-disk)))

(defvar secretary--x11idle-program-name nil)

(defvar secretary--idle-secs-fn nil)

(defvar secretary--last-online nil)

(defvar secretary--idle-beginning nil)

(defvar secretary-length-of-last-idle 0
  "Length of the last idle/offline period, in seconds.
Becomes set after that period ends and should be available at the
time `secretary-return-from-idle-hook' is run.")

(defun secretary--idle-secs ()
  "Number of seconds user has now been idle, as told by the system.
Not to be confused with `secretary-length-of-last-idle'."
  (funcall secretary--idle-secs-fn))

(defun secretary--idle-secs-x11 ()
  "Like `org-x11-idle-seconds' without /bin/sh or org."
  (/ (secretary--process-output-to-number secretary--x11idle-program-name)
     1000))

(defun secretary--idle-secs-emacs ()
  "Same as `org-emacs-idle-seconds'.
Digression: Should honestly be submitted to Emacs,
`current-idle-time' is... not normal."
  (let ((idle-time (current-idle-time)))
    (if idle-time
	(float-time idle-time)
      0)))

(defun secretary--idle-secs-gnome ()
  "Check Mutter's idea of idle time, even on Wayland."
  ;; https://unix.stackexchange.com/questions/396911/how-can-i-tell-if-a-user-is-idle-in-wayland
  (let ((idle-ms
         (string-to-number
          (car (s-match (rx space (* digit) eol)
                        (secretary--process-output-to-string
                         "dbus-send"
                         "--print-reply"
                         "--dest=org.gnome.Mutter.IdleMonitor"
                         "/org/gnome/Mutter/IdleMonitor/Core"
                         "org.gnome.Mutter.IdleMonitor.GetIdletime"))))))
    (/ idle-ms 1000)))

(defun secretary--log-idle ()
  "Log chunk of idle time to disk."
  (secretary-tsv-append secretary-idle-log-path
    (ts-format)
    (number-to-string (/ (round secretary-length-of-last-idle) 60))))

;; It's big brain time for this trio of functions...
(defun secretary--start-next-timer (&optional assume-idle)
  "Start one or the other timer depending on idleness.
If ASSUME-IDLE is non-nil, skip the idle check and associated
overhead."
  (if (or assume-idle (secretary-idle-p))
      (named-timer-run :secretary 2 nil #'secretary--user-is-idle t)
    (named-timer-run :secretary 111 nil #'secretary--user-is-present)))

(defun secretary--user-is-present ()
  "Do stuff assuming the user is active (not idle).
This function is called by `secretary--start-next-timer'
repeatedly for as long as the user is active (not idle).

Runs `secretary-periodic-present-hook'."
  ;; Guard the case where the user puts the computer to sleep manually, which
  ;; means this function will still be queued to run when the computer wakes.
  ;; If the time difference is suddenly big, hand off to the other function.
  (if (> (ts-diff (ts-now) secretary--last-online)
         secretary-idle-threshold-secs-short)
      (secretary--user-is-idle)
    (setq secretary--last-online (ts-fill (ts-now)))
    (setq secretary--idle-beginning (ts-fill (ts-now)))
    (secretary--start-next-timer)
    ;; Run hooks last, in case they contain bugs.
    (run-hooks 'secretary-periodic-present-hook)))

;; NOTE: This runs rapidly, so it should be relatively efficient
(defun secretary--user-is-idle (&optional decrement)
  "Do stuff assuming the user is idle.
This function is called by `secretary--start-next-timer'
repeatedly for as long as the user is idle.

When DECREMENT is non-nil, decrement `secretary--idle-beginning'
to correct for the time it took to reach idle status.

When the user comes back, this function will be called one last
time, at which point the idleness condition will fail and it sets
`secretary-length-of-last-idle' and runs
`secretary-return-from-idle-hook'.  That it has to run exactly
once with a failing condition that normally succeeds, as opposed
to running never or forever, is the reason it has to be a
separate function from `secretary--user-is-present'."
  (setq secretary--last-online (ts-now))
  (if (secretary-idle-p)
      (secretary--start-next-timer 'assume-idle)
    ;; Take the idle threshold into account and correct the idle begin point.
    (when decrement
      (ts-decf (ts-sec secretary--idle-beginning)
               secretary-idle-threshold-secs-short))
    (setq secretary-length-of-last-idle (ts-diff (ts-now)
                                                 secretary--idle-beginning))
    (unwind-protect
        (run-hooks 'secretary-return-from-idle-hook)
      (setq secretary--idle-beginning (ts-fill (ts-now)))
      (secretary--start-next-timer))))

(defun secretary-idle-p ()
  "Idled longer than `secretary-idle-threshold-secs-short'?"
  (> (secretary--idle-secs) secretary-idle-threshold-secs-short))


;;; Items
;; Q: What's cl-defstruct?  A: https://nullprogram.com/blog/2018/02/14/

;; NOTE: If you change the order of keys, secretary--mem-recover will set the
;; wrong values henceforth! You'd better use `secretary--mem-nuke-var' on
;; `secretary-items' then.
(cl-defstruct (secretary-item
               (:constructor secretary-item-create)
               (:copier nil))
  (dismissals 0)
  (min-hours-wait 3)
  last-called ;; almost always filled-in
  fn ;; primary key (must be unique)
  max-calls-per-day
  (max-successes-per-day nil :documentation "Alias of max-entries-per-day, more semantic where there is no dataset.")
  max-entries-per-day
  lookup-posted-time
  dataset
  ;; name ;; truly-unique key (if reusing fn in two objects for some reason)
  )

(defvar secretary-items)

(defvar secretary-disabled-fns nil
  "Which members of `secretary-items' to avoid processing.
Referred to by their :fn value.")

(defun secretary--pending-p (fn)
  "Return t if FN is due to be called."
  (let* ((i (secretary-item-by-fn fn))
         (dataset (secretary-item-dataset i))
         ;; (alt-dataset (expand-file-name (concat "successes-" (symbol-name fn))
         ;;                                secretary-cache-dir-path))
         ;; max-successes is meant as an alias for max-entries. if both are
         ;; defined, entries has precedence.
         (max-entries (secretary-item-max-entries-per-day i))
         (max-successes (or max-entries (secretary-item-max-successes-per-day i)))
         (max-entries (or max-successes (secretary-item-max-entries-per-day i)))
         (lookup-posted-time (secretary-item-lookup-posted-time i))
         (dismissals (secretary-item-dismissals i))
         (min-hrs-wait (secretary-item-min-hours-wait i))
         (min-secs-wait (* 60 60 min-hrs-wait))
         (successes-today (secretary--count-successes-today fn))
         (successes-specified-and-exceeded (and successes-today
                                                max-successes
                                                (>= successes-today max-successes)))
         (last-called (make-ts :unix (or (secretary-item-last-called i) 0)))
         (called-today (and (= (ts-day last-called) (ts-day (ts-now)))
                            (> (ts-hour last-called) 4)))
         (recently-logged
          (when (and (stringp dataset)
                     (file-exists-p dataset))
            (> min-secs-wait
               (if lookup-posted-time
                   (- (ts-unix (ts-now))
                      (string-to-number (car (secretary-tsv-last-row dataset))))
                 (ts-diff (ts-now)
                          (ts-parse (secretary-tsv-last-timestamp* dataset)))))))
         ;; Even if we didn't log yet, we don't quite want to be that persistent
         (recently-called (< (ts-diff (ts-now) last-called)
                             ;; hours multiplied by n dismissals
                             (* dismissals 60 60))))
    (unless recently-logged
      (when (or (not called-today)
                (not (and (stringp dataset)
                          (file-exists-p dataset)))
                (null max-entries)
                (> max-entries (length (secretary-tsv-entries-by-date dataset))))
        (unless recently-called
          (unless successes-specified-and-exceeded
            t))))))

(defun secretary-item-by-fn (fn)
  "Get the item associated with the query function FN."
  (--find (equal fn (secretary-item-fn it)) secretary-items))

(defun secretary-enabled-fns ()
  (-difference (-map #'secretary-item-fn secretary-items)
               secretary-disabled-fns))

(defun secretary-reenable-fn ()
  "Prompt to reenable one of the disabled items."
  (interactive)
  (if (< 0 (length secretary-disabled-fns))
      (let ((response
             (completing-read "Re-enable: "
                              (-map #'symbol-name secretary-disabled-fns))))
        (setq secretary-disabled-fns (remove response secretary-disabled-fns)))
    (message "There are no disabled items")))

(defun secretary-ask-disable (fn)
  "Ask to disable item indicated by FN.
Return non-nil on yes, and nil on no."
  (if (secretary-ynp "You have been dismissing "
                     (symbol-name fn)
                     ", shall I stop tracking it for now?")
      (push fn secretary-disabled-fns)
    (setf (secretary-item-dismissals (secretary-item-by-fn fn)) 0)
    nil))

;; NOTE: Do not move the check to secretary--pending-p, that is passive and
;; this needs interactivity.
(defun secretary-call-fn-check-dismissals (fn)
  "Call FN, but ask to disable if it's been dismissed many times."
  (interactive "CCommand: ")
  (unless (and (<= 3 (secretary-item-dismissals (secretary-item-by-fn fn)))
               (secretary-ask-disable fn))
    (funcall fn)))


;;; Persistent variables memory

(defcustom secretary-mem-history-path
  (convert-standard-filename
   (expand-file-name "memory.tsv" secretary-cache-dir-path))
  nil
  :group 'secretary
  :type 'file
  :risky t)
;; TODO: Test this
;; :set (lambda (sym val)
;;        (secretary--save-buffer-logs-to-disk)
;;        (secretary--save-vars-to-disk)
;;        (set-default sym val)))

(defcustom secretary-after-load-vars-hook nil
  "Invoked right after populating `secretary-mem' from disk.
The most recent values are therefore available.  If you've
previously saved data in that list (typically via
`secretary-before-save-vars-hook'), it should now be back even if Emacs
has restarted, so you can run something like the following.

    (setq my-var (map-elt secretary-mem 'my-var))"
  :group 'secretary
  :type 'hook)

(defcustom secretary-before-save-vars-hook nil
  "Invoked right before saving `secretary-mem' to disk.
You should add to that list anything you want to persist across
reboots, using the following.

    (secretary-mem-pushnew 'my-var)
or
    (secretary-mem-pushnew-alt my-var)

Of course, you can do that at any time, this hook isn't needed
unless you do things with 'my-var at indeterminate times and you
want to be sure what goes in before it gets written to disk."
  :group 'secretary
  :type 'hook)

(defvar secretary-mem  nil
  "Alist of all relevant variable values.
We log these values to disk at `secretary-mem-history-path', so we can
recover older values as needed.")

;; REVIEW: We may not need this
(defvar secretary--mem-timestamp-variables '(secretary--last-online)
  "List of Lisp variables that contain ts objects.
Members will be saved to `secretary-mem-history-path' as plain numbers
instead of ts objects for legibility.")

(defvar secretary--has-restored-variables nil)

(defun secretary--read-lisp (s)
  "Check that string S isn't blank, then `read' it.
Otherwise, signal an error, which `read' doesn't normally do."
  (if (and (stringp s)
           (not (string-blank-p s)))
      (car (read-from-string s))
    (error "Input should be string containing valid lisp: %s" s)))

(defun secretary--mem-nuke-var (var)
  "Remove all instances of VAR from file at `secretary-mem-history-path'.
Use with care.  Mainly for development use.

It uses `flush-lines', which is prone to mistakes (perhaps you
have multiline values, like org-capture-templates...) and may
flush other variables that merely refer to the variable name in
their value."
  (f-copy secretary-mem-history-path "/tmp/secretary-mem.backup")
  (with-temp-buffer
    (insert-file-contents secretary-mem-history-path)
    (flush-lines (symbol-name var))
    (write-file secretary-mem-history-path)))

(defun secretary--mem-filter-for-variable (var)
  "Get all occurrences of VAR from `secretary-mem-history-path'.
Return a list looking like
\((TIMESTAMP KEY VALUE) (TIMESTAMP KEY VALUE) ...)."
  (let* ((table (secretary-tsv-all-entries secretary-mem-history-path))
         (table-subset (--filter (eq var (secretary--read-lisp (cadr it)))
                                 table)))
    table-subset))

(defun secretary--mem-check-history-sanity ()
  "Check that the mem history is sane."
  (unless (--all-p (= 3 (length it))
                   (secretary-tsv-all-entries secretary-mem-history-path))
    (error "Memory looks corrupt: not all lines have 3 fields")))

(defun secretary--mem-save-only-changed-vars ()
  "Save new or changed `secretary-mem' values to disk."
  (secretary--mem-check-history-sanity)
  (cl-loop for cell in secretary-mem
           do (progn
                (let ((foo (secretary--mem-filter-for-variable (car cell)))
                      (write? nil)
                      ;; Configure `prin1-to-string'.
                      (print-level nil)
                      (print-length nil))
                  (if (null foo)
                      (setq write? t)
                    (unless (equal (cdr cell)
                                   (secretary--read-lisp
                                    (nth 2 (-last-item foo))))
                      (setq write? t)))
                  (when write?
                    (secretary-tsv-append secretary-mem-history-path
                      (prin1-to-string (car cell))
                      (if (ts-p (cdr cell))
                          ;; Convert ts structs because they're clunky to read
                          (ts-format "%s" (cdr cell))
                        (prin1-to-string (cdr cell)))))))))

(defun secretary--mem-last-value-of-variable (var)
  "Get the most recent stored value of VAR from disk."
    (let* ((table (nreverse (secretary-tsv-all-entries
                             secretary-mem-history-path)))
           (ok t))
      (cl-block nil
        (while ok
          (let ((row (pop table)))
            (when (eq (secretary--read-lisp (nth 1 row)) var)
              (setq ok nil)
              (cl-return (read (nth 2 row)))))))))

(defun secretary--mem-recover ()
  "Read the newest values from file at `secretary-mem-history-path'.
Assign them to the same names inside the alist
`secretary-mem'."
  (let* ((table (-map #'cdr (nreverse (secretary-tsv-all-entries
                                       secretary-mem-history-path)))))
    (while (/= 0 (length table))
      (let* ((row (pop table))
             (parsed-row (-map #'secretary--read-lisp row)))
        (unless (member (car parsed-row) (map-keys secretary-mem))
          ;; Convert numbers back into ts objects.
          (when (member (car parsed-row) secretary--mem-timestamp-variables)
            (setf (cadr parsed-row) (ts-fill (make-ts :unix (cadr parsed-row)))))
          (setq secretary-mem (cons (cons  (car parsed-row) (cadr parsed-row))
                                       secretary-mem)))))))

(defun secretary--mem-restore-items-values ()
  "Sync some values of current `secretary-items' members from disk.
The values are :last-called and :dismissals, because they are of
interest to persist across sessions."
  (dolist (disk-item (map-elt secretary-mem 'secretary-items))
    (unless (ignore-errors (let* ((fn-sym (secretary-item-fn disk-item))
                                   (active-item (when (fboundp fn-sym)
                                                  (secretary-item-by-fn fn-sym))))
                             ;; if it reflects something we have defined currently
                             (when (fboundp fn-sym)
                               ;;  update the current one's :dismissals etc to match on-disk values.
                               (setf (secretary-item-dismissals active-item)
                                 (secretary-item-dismissals disk-item))
                               (setf (secretary-item-last-called active-item)
                                 (secretary-item-last-called disk-item)))
                             t))
      (warn
        (s-join "\n"
          '("secretary--mem-restore-items-values failed. "
             " Did you change the secretary-item defstruct?"
             " Not critical so proceeding.  May self-correct next sync."))))))

;; TODO: Calc all reasonable defaults we can from known dataset contents (we
;;       already do it some but we can do more).
(defun secretary--init ()
  "Master function restoring all relevant variables.
Appropriate on init."
  (secretary--mem-recover)
  (setq secretary--last-online
        (ts-fill
         ;; TODO: error if there are older non-nil values and it's now nil
         (or (map-elt secretary-mem 'secretary--last-online)
             (make-ts :unix 0))))
  (when (and secretary-chat-log-path
             (f-exists? secretary-chat-log-path))
    (let ((chatfile-modtime-unix
           (time-convert (file-attribute-modification-time
                          (file-attributes secretary-chat-log-path))
                         'integer))
          (remembered (map-elt secretary-mem 'secretary--last-chatted)))
      (setq secretary--last-chatted
            (ts-fill
             (make-ts :unix (max chatfile-modtime-unix
                                 (if secretary--last-chatted
                                     (ts-unix secretary--last-chatted)
                                   0)
                                 (if remembered
                                     (ts-unix remembered)
                                   0)))))))
  (when (and (boundp 'secretary--last-chatted)
             (ts-p secretary--last-chatted)
             (ts< secretary--last-online secretary--last-chatted))
    (setq secretary--last-online secretary--last-chatted))
  (setq secretary--idle-beginning secretary--last-online)
  (secretary--mem-restore-items-values)
  (run-hooks 'secretary-after-load-vars-hook)
  (setq secretary--has-restored-variables t))

(defun secretary--save-vars-to-disk ()
  "Sync all relevant variables to disk."
  (unless secretary--has-restored-variables
    (error "Attempted to save variables to disk, but never fully \n%s\n%s\n%s"
           "restored them from disk first, so the results would have been"
           "built on blank data, which is not right.  Please post an issue:"
           "https://github.com/meedstrom/secretary (even if you fix it)"))
  (secretary-mem-pushnew 'secretary--last-online)
  (secretary-mem-pushnew 'secretary-items)
  (secretary-mem-pushnew 'secretary-disabled-fns)
  (make-directory secretary-cache-dir-path t)
  (when secretary-chat-log-path
    (secretary-write-safely (with-current-buffer (secretary--buffer-chat)
                              (buffer-string))
                            secretary-chat-log-path))
  (run-hooks 'secretary-before-save-vars-hook)
  (secretary--mem-save-only-changed-vars))

(defun secretary-mem-pushnew (var)
  "In `secretary-mem', store variable VAR's current value.
You should quote VAR, like with `set', not `setq'."
  (if (assoc var secretary-mem)
      (map-put! secretary-mem var (symbol-value var))
    (setq secretary-mem
          (map-insert secretary-mem var (symbol-value var)))))

(defmacro secretary-mem-pushnew-alt (var)
  "In `secretary-mem', store variable VAR's current value."
  `(if (assoc ',var secretary-mem)
       (map-put! secretary-mem ',var ,var)
     (setq secretary-mem
           (map-insert secretary-mem ',var ,var))))


;;; Buffer logger
;; Unlike most data sources which make only the occasional datapoint, this
;; logger produces constant reams of new data, so we write them temporarily to
;; a buffer, bundling up what would otherwise be many disk write ops.

(defcustom secretary-buffer-focus-log-path
  (convert-standard-filename "~/self-data/buffer-focus.tsv")
  "Where to save the log of buffer focus changes."
  :group 'secretary
  :type 'file)

(defcustom secretary-buffer-info-path
  (convert-standard-filename "~/self-data/buffer-info.tsv")
  "Where to save the log of buffer metadata."
  :group 'secretary
  :type 'file)

(defvar secretary--last-buffer nil)

(defvar secretary--known-buffers nil
  "Buffers the user has entered this Emacs session.")

(defvar secretary--buffer-focus-log-buffer
  (get-buffer-create
   (concat (unless secretary-debug " ") "*Secretary: Buffer focus log*")
   (not secretary-debug))
  "Buffer for not-yet-saved log lines.")

(defvar secretary--buffer-info-buffer
  (get-buffer-create
   (concat (unless secretary-debug " ") "*Secretary: Buffer info*")
   (not secretary-debug))
  "Buffer for not-yet-saved log lines.")

(defun secretary--new-uuid ()
  "Same as `org-id-uuid', but avoid relying on Org."
  (declare (side-effect-free t))
  (let ((rnd (md5 (format "%s%s%s%s%s%s%s"
                          (random)
                          (seconds-to-time (float-time))
                          (user-uid)
                          (emacs-pid)
                          (user-full-name)
                          user-mail-address
                          (recent-keys)))))
    (format "%s-%s-4%s-%s%s-%s"
            (substring rnd 0 8)
            (substring rnd 8 12)
            (substring rnd 13 16)
            (format "%x"
                    (logior
                     #b10000000
                     (logand
                      #b10111111
                      (string-to-number
                       (substring rnd 16 18) 16))))
            (substring rnd 18 20)
            (substring rnd 20 32))))

(defun secretary--save-buffer-logs-to-disk ()
  "Append as-yet unwritten log lines to disk files."
  (secretary--transact-buffer-onto-file secretary--buffer-focus-log-buffer
                                        secretary-buffer-focus-log-path)
  (secretary--transact-buffer-onto-file secretary--buffer-info-buffer
                                        secretary-buffer-info-path))

;; TODO: When buffer major mode changes, count it as a new buffer. Note that
;;       (assoc buf secretary--known-buffers) will still work.
;; TODO: When eww url changes, count it as a new buffer
;; TODO: When counting it as a new buffer, record a field for "previous uuid"
;;       just in case the data analyst wants to merge these observations
;; TODO: Optimize?
(defun secretary--log-buffer (&optional _arg)
  "Log the buffer just switched to.
Put this on `window-buffer-change-functions' and
`window-selection-change-functions'."
  (unless (minibufferp)
    (let* ((buf (current-buffer))
           (mode (symbol-name major-mode))
           (known (assoc buf secretary--known-buffers))
           (timestamp (ts-format "%s.%N"))
           (visiting (if (eq major-mode 'dired-mode)
                         default-directory
                       buffer-file-name))
           (eww-url (when (eq major-mode 'eww-mode)
                      (eww-current-url)))
           (exist-record (unless (and known
                                      ;; TODO: make a new exist-record when mode changes
                                      (equal mode (nth 4 known))) ;; doesnt do it
                           (list buf
                                 (secretary--new-uuid)
                                 (buffer-name)
                                 visiting
                                 mode
                                 timestamp ;; time the buffer was first opened
                                 eww-url
                                 (when (equal mode "exwm-mode") exwm-class-name)
                                 (when (equal mode "exwm-mode") exwm-title))))
           (focus-record (list timestamp ;; time the buffer was switched to
                               ;; the buffer's uuid
                               (if known (cadr known) (cadr exist-record)))))
      (unless (eq secretary--last-buffer buf) ; only entered/left minibuffer
        (setq secretary--last-buffer buf)
        (unless known
          (push exist-record secretary--known-buffers)
          (with-current-buffer secretary--buffer-info-buffer
            (goto-char (point-max))
            (insert "\n" (string-join (cdr exist-record) "\t"))))
        (with-current-buffer secretary--buffer-focus-log-buffer
          (goto-char (point-max))
          (insert "\n" (string-join focus-record "\t")))))))


;;; Interactive sessions

(defvar secretary-debug-no-timid nil)

(defalias 'secretary-resume #'secretary-execute)

(defun secretary-execute (&optional queue)
  "Call every function from QUEUE, default `secretary--queue'.
Does some checks and sets up a good environment, in particular
nulling the 'buffer-predicate frame parameter so that no buffers
spawned by the functions will be skipped by
`switch-to-next-buffer'."
  (interactive)
  (named-timer-cancel :secretary-excursion) ;; hygiene
  (let ((bufpred-backup (frame-parameter nil 'buffer-predicate)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'buffer-predicate nil)
          (pop-to-buffer (secretary--buffer-chat))
          (dolist (f (or queue secretary--queue))
            (secretary-call-fn-check-dismissals f)))
      ;; FIXME: Actually, this will executed at the first keyboard-quit, so we
      ;; will never have a nil predicate. We need to preserve it during an
      ;; excursion.
      (set-frame-parameter nil 'buffer-predicate bufpred-backup))))

(defun secretary-butt-in-gently ()
  "Butt in if any queries are pending, with an introductory chime."
  (setq secretary-date (ts-now))
  (when-let ((fns (if secretary-debug-no-timid
                      (secretary-enabled-fns)
                    (-filter #'secretary--pending-p (secretary-enabled-fns)))))
    (setq secretary--queue fns)
    (unless (eq t (frame-focus-state))
      (require 'notifications)
      (notifications-notify :title secretary-ai-name :body (secretary-greeting)))
    (secretary--chime-aural)
    (secretary--chime-visual)
    (run-with-timer 1 nil #'secretary-execute)))

(defun secretary-session-from-idle ()
  "Start a session if idle was long."
  (unless (< secretary-length-of-last-idle secretary-idle-threshold-secs-long)
    (secretary-butt-in-gently)))

(defun secretary-new-session ()
  "Recalculate what items are pending and run them."
  (interactive)
  (setq secretary-date (ts-now))
  (setq secretary--queue
        (-filter #'secretary--pending-p (secretary-enabled-fns)))
  (secretary-execute))

(defun secretary-new-session-force-all ()
  "Run through all enabled items."
  (interactive)
  (setq secretary-date (ts-now))
  (setq secretary--queue (secretary-enabled-fns))
  (secretary-execute))


;;; Commands

(defun secretary-decrement-date ()
  "Decrement `secretary-date'."
  (interactive nil secretary-chat-mode)
  (secretary-set-date (ts-dec 'day 1 secretary-date)))

(defun secretary-increment-date ()
  "Increment `secretary-date'."
  (interactive nil secretary-chat-mode)
  (secretary-set-date (ts-inc 'day 1 secretary-date)))

(defun secretary-set-date-today ()
  "Set `secretary-date' to today."
  (interactive)
  (secretary-set-date (ts-now)))

(defun secretary-set-date (&optional ts)
  "Decrement `secretary-date' from `org-read-date'.
Optional arg TS skips the prompt and sets date from that."
  (interactive)
  (require 'org)
  (if ts
      (setq secretary-date ts)
    (let* ((time (ts-format "%T"))
           (new-date (org-read-date))
           (new-datetime (ts-parse (concat new-date " " time))))
      (setq secretary-date new-datetime)))
  (secretary-emit
   "Operating as if the date is " (ts-format "%x" secretary-date) "."))


;;; Modes and keys

(defvar secretary-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'secretary-resume)
    (define-key map (kbd "+") #'secretary-increment-date)
    (define-key map (kbd "-") #'secretary-decrement-date)
    (define-key map (kbd "0") #'secretary-set-date-today)
    (define-key map (kbd "d") #'secretary-set-date)
    (define-key map (kbd "q") #'bury-buffer)
    (define-key map (kbd "?") #'secretary-dispatch)
    (define-key map (kbd "h") #'secretary-dispatch)
    map))

(define-derived-mode secretary-chat-mode text-mode "Secretary chat")

(transient-define-prefix secretary-dispatch ()
  ["General actions"
   ("q" "Quit the chat" bury-buffer)
   ]
  ["Date"
   ("0" "Reset date to today (default)" secretary-set-date-today :transient t)
   ("-" "Decrement the date" secretary-decrement-date :transient t)
   ("+" "Increment the date" secretary-increment-date :transient t)
   ("d" "Set date..." secretary-set-date :transient t)
   ])


;;; "Main": startup stuff

(defun secretary--check-for-time-anomalies ()
  "Check for timestamps that don't look right.
Good to run after enabling `secretary-mode' or changing
`secretary-items'."
  (let* ((datasets (--map (secretary-item-dataset it) secretary-items))
         (logs (list secretary-idle-log-path
                     secretary-buffer-focus-log-path))
         (files (-non-nil (append datasets logs)))
         (anomalous-files nil))
    (dolist (f files)
      (when (f-exists-p f)
        (let ((stamps (->> (secretary-tsv-all-entries f)
                           (map-keys) ;; first elem of each row
                           (-map #'string-to-number))))
          (unless (<= stamps)
            (message (concat "Timestamps not strictly increasing in: " f)))
          ;; Check that no timestamp bigger than current time.
          (if (--any-p (> it (float-time)) stamps)
              (push f anomalous-files)))))
    (when anomalous-files
      (warn (->> (append
                  '("Secretary: Anomalous timestamps found in my logs."
                    "You probably have or have had a wrong system clock."
                    "These files have timestamps exceeding the current time:")
                  anomalous-files)
                 (s-join "\n"))))))

(defun secretary--keepalive ()
  "Re-start the :secretary timer if dead.
Indispensable while hacking on the package."
  (unless (member (named-timer-get :secretary) timer-list)
    (message "[%s] secretary timer found dead, reviving it."
             (format-time-string "%H:%M"))
    (secretary--start-next-timer)))

(defun secretary--another-secretary-running-p ()
  "Return t if another Emacs instance has secretary-mode on.
Return nil if only the current Emacs instance or none has it on.
If you've somehow forced it on in several Emacsen, the behavior
is unspecified, but it shouldn't be possible to do."
  (when (file-exists-p "/tmp/secretary/pid")
    (let ((pid (string-to-number (f-read-bytes "/tmp/secretary/pid"))))
      (and (/= pid (emacs-pid))
           (member pid (list-system-processes))))))

(defun secretary--emacs-init-message ()
  "Emit the message that Emacs has started.
So that we can see in the chat log when Emacs was (re)started,
creating some context."
  (when secretary--has-restored-variables
    (secretary-emit "------ Emacs (re)started. ------")))

(defun secretary--idle-set-fn ()
  "Set `secretary--idle-secs-fn' to an appropriate function.
Return the function on success, nil otherwise."
  (or (symbol-value 'secretary--idle-secs-fn)  ; if preset, use that.
      (and (eq system-type 'darwin)
           (autoload #'org-mac-idle-seconds "org-clock")
           (setq secretary--idle-secs-fn #'org-mac-idle-seconds))
      ;; If under Mutter's Wayland compositor
      (and (getenv "DESKTOP_SESSION")
           (s-matches-p (rx (or "gnome" "ubuntu"))
                        (getenv "DESKTOP_SESSION"))
           (not (s-contains-p "xorg"
                              (getenv "DESKTOP_SESSION")))
           (setq secretary--idle-secs-fn #'secretary--idle-secs-gnome))
      ;; NOTE: This condition is true under XWayland, so it must come
      ;; after any check for Wayland if we want it to mean X only.
      (and (eq window-system 'x)
           (setq secretary--x11idle-program-name
                 (seq-find #'executable-find '("x11idle" "xprintidle")))
           (setq secretary--idle-secs-fn #'secretary--idle-secs-x11))
      (and (symbol-value 'secretary-fallback-to-emacs-idle)
           (setq secretary--idle-secs-fn #'secretary--idle-secs-emacs))))

(defun secretary-unload-function ()
  "Unload the Secretary library."
  (secretary-mode 0)
  (with-demoted-errors nil
    (unload-feature 'secretary-tests)
    (unload-feature 'secretary-config)
    (unload-feature 'secretary-activity)
    (unload-feature 'secretary-builtin))
  ;; Continue standard unloading.
  nil)

;;;###autoload
(define-minor-mode secretary-mode
  "Wake up the secretary."
  :global t
  (if secretary-mode
      (progn
        (when secretary-debug
          (secretary-emit "------ (debug message) Trying to turn on. ------"))
        ;; Check to see whether it's ok to turn on.
        (when (and (or (secretary--idle-set-fn)
                       (prog1 nil
                         (message
                          (concat secretary-ai-name
                                  ": Not able to detect idleness, I'll be"
                                  " useless.  Disabling secretary-mode."))
                         (secretary-mode 0)))
                   (if (secretary--another-secretary-running-p)
                       (prog1 nil
                         (message "Another secretary active.")
                         (secretary-mode 0))
                     t))
          ;; All OK, turn on.
          (mkdir "/tmp/secretary" t)
          (f-write (number-to-string (emacs-pid)) 'utf-8 "/tmp/secretary/pid")
          (add-function :after after-focus-change-function
                        #'secretary--log-buffer)
          (add-hook 'window-buffer-change-functions #'secretary--log-buffer)
          (add-hook 'window-selection-change-functions #'secretary--log-buffer)
          (add-hook 'after-init-hook #'secretary--init -90)
          (add-hook 'after-init-hook #'secretary--emacs-init-message 1)
          (add-hook 'after-init-hook #'secretary--check-for-time-anomalies 2)
          (add-hook 'after-init-hook #'secretary--init-r 3)
          (add-hook 'after-init-hook #'secretary--start-next-timer 90)
          (named-timer-run :secretary-keepalive 300 300 #'secretary--keepalive)
          (when after-init-time
            (progn
              (secretary--init)
              (secretary--check-for-time-anomalies)
              (secretary--init-r)
              (secretary--user-is-present)
              (when secretary-debug
                (secretary-emit
                 "------ (debug message) Mode turned on. ------"))))))
    ;; Turn off.
    (unless (secretary--another-secretary-running-p)
      (secretary-emit "Turning off.")
      (secretary--save-vars-to-disk)
      (ignore-errors (f-delete "/tmp/secretary/pid")))
    (setq secretary--idle-secs-fn nil)
    (remove-function after-focus-change-function #'secretary--log-buffer)
    (remove-hook 'window-buffer-change-functions #'secretary--log-buffer)
    (remove-hook 'window-selection-change-functions #'secretary--log-buffer)
    (remove-hook 'after-init-hook #'secretary--init)
    (remove-hook 'after-init-hook #'secretary--emacs-init-message)
    (remove-hook 'after-init-hook #'secretary--check-for-time-anomalies)
    (remove-hook 'after-init-hook #'secretary--init-r)
    (remove-hook 'after-init-hook #'secretary--start-next-timer)
    (named-timer-cancel :secretary)
    (named-timer-cancel :secretary-keepalive)))

(provide 'secretary)

;;; secretary.el ends here
