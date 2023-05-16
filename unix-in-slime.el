;;; unix-in-slime.el --- Unix in Lisp support for SLIME -*- lexical-binding: t; -*-

;; Author: Sakurakouji Sena <qhong@alum.mit.edu>
;; Maintainer: Sakurakouji Sena <qhong@alum.mit.edu>
;; Package-Requires: ((emacs "28") (slime "2.27"))
;; Keywords: lisp
;; URL: https://gitub.com/PuellaeMagicae/unix-in-lisp
;; Version: 0.1

;; This file is NOT part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package adds ANSI colors and escape sequence to the SLIME REPL.

;;; Code:


(require 'ansi-color)
(require 'nadvice)
(require 'slime)

(define-advice slime-repl-emit
    (:after (string) unix-in-slime)
  (with-current-buffer (slime-output-buffer)
    (comint-carriage-motion slime-output-start slime-output-end)
    (ansi-color-apply-on-region slime-output-start slime-output-end)))

(defvar unix-in-slime-port nil)

;;;###autoload
(defun unix-in-slime ()
  "Create a SLIME listener running Unix in Lisp."
  (interactive)
  (if (slime-connected-p)
      (slime-eval-async
          '(cl:progn
            (asdf:require-system "unix-in-lisp")
            (cl:funcall (cl:find-symbol "INSTALL" "UNIX-IN-LISP") t)
            (cl:or (cl:symbol-value (cl:find-symbol "*SWANK-PORT*" "UNIX-IN-LISP"))
                   (cl:set (cl:find-symbol "*SWANK-PORT*" "UNIX-IN-LISP")
                           (swank:create-server :dont-close t))))
        (lambda (port)
          (setq unix-in-slime-port port)
          ;; don't let `slime-connect' change default connection
          (let ((slime-default-connection slime-default-connection))
            (slime-connect "localhost" port)
            (slime-eval-async
                '(cl:funcall (cl:find-symbol "SETUP" "UNIX-IN-LISP"))))))
    (save-selected-window (slime-start :init-function #'unix-in-slime))))

(defun unix-in-slime-p ()
  (when (and unix-in-slime-port (slime-connection))
    (equal (cadr (process-contact (slime-connection)))
           unix-in-slime-port)))

(defun unix-in-slime-disconnect-maybe ()
  (when (and (derived-mode-p 'slime-repl-mode) (unix-in-slime-p))
    (remove-hook 'kill-buffer-hook 'unix-in-slime-disconnect-maybe t)
    (slime-disconnect)))

(add-hook 'kill-buffer-hook #'unix-in-slime-disconnect-maybe)

(define-advice slime-repl-insert-prompt
    (:after () unix-in-slime)
  (let ((prompt (slime-lisp-package-prompt-string)))
    (when (file-name-absolute-p prompt)
      (setq-local default-directory
                  (substring (file-name-concat prompt "x") 0 -1)))))

(provide 'unix-in-slime)
;;; unix-in-slime.el ends here
