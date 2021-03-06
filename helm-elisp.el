;;; helm-elisp.el --- Elisp symbols completion for helm.

;; Copyright (C) 2012 Thierry Volpiatto <thierry.volpiatto@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:
(eval-when-compile (require 'cl))
(require 'helm)
(require 'helm-utils)
(require 'advice)

;;; Show completion.
;;
;; Provide show completion with macro `with-helm-show-completion'.


;; Called each time cursor move in helm-buffer.
(defun helm-c-show-completion ()
  (with-helm-current-buffer
    (overlay-put helm-c-show-completion-overlay
                 'display (helm-get-selection))))

(defun helm-c-show-completion-init-overlay (beg end)
  (and helm-c-turn-on-show-completion
       (setq helm-c-show-completion-overlay (make-overlay beg end))
       (overlay-put helm-c-show-completion-overlay
                    'face 'helm-lisp-show-completion)))

(defun helm-c-show-completion-display-function (buffer)
  "A special resized helm window is used depending on position in BUFFER."
  (with-selected-window (selected-window)
    (let* ((screen-size  (+ (count-screen-lines (window-start) (point) t)
                            1                             ; mode-line
                            (if header-line-format 1 0))) ; header-line
           (def-size     (- (window-height)
                            helm-c-show-completion-min-window-height))
           (upper-height (max window-min-height (min screen-size def-size)))
           split-window-keep-point)
      (recenter -1)
      (set-window-buffer (if (active-minibuffer-window)
                             (minibuffer-selected-window)
                             (split-window nil upper-height))
                         buffer))))

(defmacro with-helm-show-completion (beg end &rest body)
  "Show helm candidate in an overlay at point.
BEG and END are the beginning and end position of the current completion
in `helm-current-buffer'.
BODY is an helm call where we want to enable show completion.
If `helm-c-turn-on-show-completion' is nil just do nothing."
  (declare (indent 2) (debug t))
  `(let ((helm-move-selection-after-hook
          (and helm-c-turn-on-show-completion
               (append (list 'helm-c-show-completion)
                       helm-move-selection-after-hook))))
     (unwind-protect
          (progn
            (helm-c-show-completion-init-overlay ,beg ,end)
            (let ((helm-display-function
                   (if helm-c-show-completion-use-special-display
                       'helm-c-show-completion-display-function
                       'helm-default-display-buffer)))
              ,@body))
       (and helm-c-turn-on-show-completion
            (delete-overlay helm-c-show-completion-overlay)))))


;;; Lisp symbol completion.
;;
;;
;;;###autoload
(defun helm-lisp-completion-at-point ()
  "Helm lisp symbol completion at point."
  (interactive)
  (let* ((data       (lisp-completion-at-point))
         (beg        (car data))
         (end        (point)) ; 'cadr data' is wrong when no space after point.
         (plist      (nthcdr 3 data))
         (pred       (plist-get plist :predicate))
         (lgst-len   0)
         (target     (and beg end (buffer-substring-no-properties beg end)))
         (candidates (all-completions target (nth 2 data) pred))
         (helm-quit-if-no-candidate t)

         (helm-execute-action-at-once-if-one t)
         (helm-match-plugin-enabled
          (member 'helm-compile-source--match-plugin
                  helm-compile-source-functions)))
    (if candidates
        (with-helm-show-completion beg end
          ;; Overlay is initialized now in helm-current-buffer.
          (helm
           :sources
           '((name . "Lisp completion")
             (init . (lambda ()
                       (with-current-buffer (helm-candidate-buffer 'global)
                         (loop for sym in candidates
                               for len = (length sym)
                               when (> len lgst-len) do (setq lgst-len len)
                               do (insert (concat sym "\n"))))))
             (candidates-in-buffer)
             (persistent-action . helm-lisp-completion-persistent-action)
             (persistent-help . "Show brief doc in mode-line")
             (filtered-candidate-transformer helm-lisp-completion-transformer)
             (action . (lambda (candidate)
                         (delete-region beg end)
                         (insert candidate))))
           :input (if helm-match-plugin-enabled (concat target " ") target)))
        (message "[No Match]"))))

(defun helm-lisp-completion-persistent-action (candidate)
  (let ((cursor-in-echo-area t)
        mode-line-in-non-selected-windows)
    (helm-c-show-info-in-mode-line
     (propertize
      (helm-c-get-first-line-documentation
       (intern candidate))
      'face 'helm-lisp-completion-info))))

(defun helm-lisp-completion-transformer (candidates source)
  "Helm candidates transformer for lisp completion."
  (declare (special lgst-len))
  (loop for c in candidates
        for sym = (intern c)
        for annot = (cond ((commandp sym) " (Com)")
                          ((fboundp sym)  " (Fun)")
                          ((boundp sym)   " (Var)")
                          ((facep sym)    " (Face)"))
        for spaces = (make-string (- lgst-len (length c)) ? )
        collect (cons (concat c spaces annot) c)))

(defun helm-c-get-first-line-documentation (sym)
  "Return first line documentation of symbol SYM.
If SYM is not documented, return \"Not documented\"."
  (let ((doc (cond ((fboundp sym)
                    (documentation sym t))
                   ((boundp sym)
                    (documentation-property sym 'variable-documentation t))
                   ((facep sym)
                    (face-documentation sym))
                   (t nil))))
    (if (and doc (not (string= doc ""))
             ;; `documentation' return "\n\n(args...)"
             ;; for CL-style functions.
             (not (string-match-p "^\n\n" doc)))
        (car (split-string doc "\n"))
        "Not documented")))

;;; File completion.
;;
;; Complete file name at point.
(defun helm-c-thing-before-point ()
  "Get symbol name before point."
  (save-excursion
    (let ((beg (point)))
      ;; older regexp "\(\\|\\s-\\|^\\|\\_<\\|\r\\|'\\|#'"
      (when (re-search-backward
             "\\_<" (field-beginning nil nil (point-at-bol)) t)
        (buffer-substring-no-properties beg (match-end 0))))))

;;;###autoload
(defun helm-c-complete-file-name-at-point ()
  "Complete file name at point."
  (interactive)
  (let* ((init (substring-no-properties (thing-at-point 'filename)))
         (end  (point))
         (beg  (- (point) (length init)))
         (helm-quit-if-no-candidate t)
         (helm-execute-action-at-once-if-one t)
         completion)
    (with-helm-show-completion beg end
      (setq completion (helm-c-read-file-name "FileName: "
                                              :initial-input init)))
    (helm-c-insert-file-name-completion-at-point completion)))

;; Internal
(defvar helm-lisp-completion-counter 0)
;;;###autoload
(defun helm-lisp-completion-at-point-or-indent (arg)
  "First call indent and second call complete lisp symbol.
The second call should happen before `helm-lisp-completion-or-indent-delay',
after this delay, next call will indent again.
After completion, next call is always indent.
See that like click and double mouse click.
One hit indent, two quick hits maybe indent and complete."
  (interactive "P")
  ;; Be sure `indent-for-tab-command' will not try
  ;; to use `completion-at-point'.
  (let ((tab-always-indent (if (eq tab-always-indent 'complete)
                               t tab-always-indent)))
    (incf helm-lisp-completion-counter)
    (unwind-protect
         (if (> helm-lisp-completion-counter 1)
             (helm-lisp-completion-or-file-name-at-point)
             (indent-for-tab-command arg))
      ;; After `helm-lisp-completion-or-indent-delay' seconds
      ;; reset to 0.
      (run-with-timer helm-lisp-completion-or-indent-delay nil
                      #'(lambda ()
                          (setq helm-lisp-completion-counter 0)))
      ;; Always reset to 0 at second hit.
      (when (eq helm-lisp-completion-counter 2)
        (setq helm-lisp-completion-counter 0)))))

;;;###autoload
(defun helm-lisp-completion-or-file-name-at-point ()
  "Complete lisp symbol or filename at point.
Filename completion happen if filename is started in
or between double quotes."
  (interactive)
  (let ((tap (substring-no-properties (thing-at-point 'filename))))
    (if (and tap (string-match "^\\(~/\\|/\\|[a-zA-Z]\:/\\).*" tap)
             (save-excursion (search-backward "\"" (point-at-bol) t)))
        (helm-c-complete-file-name-at-point)
        (helm-lisp-completion-at-point))))

(defun helm-c-apropos-init (test default)
  "Init candidates buffer for `helm-c-apropos' sources."
  (with-current-buffer (helm-candidate-buffer 'global)
    (goto-char (point-min))
    (when (and default (stringp default)
               ;; Some defaults args result as
               ;; (symbol-name nil) == "nil".
               ;; e.g debug-on-entry.
               (not (string= default "nil"))
               (funcall test (intern default)))
      (insert (concat default "\n")))
    (loop with all = (all-completions "" obarray test)
          for sym in all
          unless (and default (eq sym default))
          do (insert (concat sym "\n")))))

;;;###autoload
(defun helm-c-apropos ()
  "Preconfigured helm to describe commands, functions, variables and faces."
  (interactive)
  (let ((default (thing-at-point 'symbol)))
    (helm :sources
          `(((name . "Commands")
             (init . (lambda ()
                       (helm-c-apropos-init 'commandp ,default)))
             (persistent-action . helm-lisp-completion-persistent-action)
             (persistent-help . "Show brief doc in mode-line")
             (candidates-in-buffer)
             (action . (lambda (candidate)
                         (describe-function (intern candidate)))))
            ((name . "Functions")
             (init . (lambda ()
                       (helm-c-apropos-init #'(lambda (x) (and (fboundp x)
                                                               (not (commandp x))))
                                            ,default)))
             (persistent-action . helm-lisp-completion-persistent-action)
             (persistent-help . "Show brief doc in mode-line")
             (candidates-in-buffer)
             (action . (lambda (candidate)
                         (describe-function (intern candidate)))))
            ((name . "Variables")
             (init . (lambda ()
                       (helm-c-apropos-init 'boundp ,default)))
             (persistent-action . helm-lisp-completion-persistent-action)
             (persistent-help . "Show brief doc in mode-line")
             (candidates-in-buffer)
             (action . (lambda (candidate)
                         (describe-variable (intern candidate)))))
            ((name . "Faces")
             (init . (lambda ()
                       (helm-c-apropos-init 'facep ,default)))
             (persistent-action . helm-lisp-completion-persistent-action)
             (persistent-help . "Show brief doc in mode-line")
             (candidates-in-buffer)
             (filtered-candidate-transformer . (lambda (candidates source)
                                                 (loop for c in candidates
                                                       collect (propertize c 'face (intern c)))))
             (action . (lambda (candidate)
                         (describe-face (intern candidate)))))
            ((name . "Helm attributes")
             (candidates . (lambda ()
                             (mapcar 'symbol-name helm-additional-attributes)))
             (action . (lambda (candidate)
                         (with-output-to-temp-buffer "*Help*"
                           (princ (get (intern candidate) 'helm-attrdoc))))))))))

(defvar helm-c-source-advice
  '((name . "Function Advice")
    (candidates . helm-c-advice-candidates)
    (action ("Toggle Enable/Disable" . helm-c-advice-toggle))
    (persistent-action . helm-c-advice-persistent-action)
    (multiline)
    (persistent-help . "Describe function / C-u C-z: Toggle advice")))
;; (let ((debug-on-signal t))(helm 'helm-c-source-advice))
;; (testadvice)

(defun helm-c-advice-candidates ()
  (loop for (fname) in ad-advised-functions
        for function = (intern fname)
        append
        (loop for class in ad-advice-classes append
              (loop for advice in (ad-get-advice-info-field function class)
                    for enabled = (ad-advice-enabled advice)
                    collect
                    (cons (format
                           "%s %s %s"
                           (if enabled "Enabled " "Disabled")
                           (propertize fname 'face 'font-lock-function-name-face)
                           (ad-make-single-advice-docstring advice class nil))
                          (list function class advice))))))

(defun helm-c-advice-persistent-action (func-class-advice)
  (if current-prefix-arg
      (helm-c-advice-toggle func-class-advice)
      (describe-function (car func-class-advice))))

(defun helm-c-advice-toggle (func-class-advice)
  (destructuring-bind (function class advice) func-class-advice
    (cond ((ad-advice-enabled advice)
           (ad-advice-set-enabled advice nil)
           (message "Disabled"))
          (t                            ;disabled
           (ad-advice-set-enabled advice t)
           (message "Enabled")))
    (ad-activate function)
    (and helm-in-persistent-action
         (helm-c-advice-update-current-display-string))))

(defun helm-c-advice-update-current-display-string ()
  (helm-edit-current-selection
    (let ((newword (cond ((looking-at "Disabled") "Enabled")
                         ((looking-at "Enabled")  "Disabled")))
          realvalue)
      (when newword
        (delete-region (point) (progn (forward-word 1) (point)))
        (insert newword)))))

;;;###autoload
(defun helm-manage-advice ()
  "Preconfigured `helm' to disable/enable function advices."
  (interactive)
  (helm-other-buffer 'helm-c-source-advice "*helm advice*"))

;;; Complex command history
;;
;;
(defvar helm-c-source-complex-command-history
  '((name . "Complex Command History")
    (candidates . (lambda () (mapcar 'prin1-to-string command-history)))
    (type . sexp)))

;;;###autoload
(defun helm-complex-command-history ()
  (interactive)
  (helm :sources 'helm-c-source-complex-command-history
        :buffer "*helm complex commands*"))

(provide 'helm-elisp)

;;; helm-elisp.el ends here
