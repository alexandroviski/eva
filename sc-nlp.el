;;; sc-nlp.el -*- lexical-binding: t; -*-
;; Copyright (C) 2020 Martin Edström

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

;;; Code:

;; wip
(defun sc-parse-command (input)
  (let ((input "foo"))
    (cond ((string-match-p (rx "later") input)
           'reschedule)
          ((string-match-p (rx "later") input)
           'reschedule)
          ((string-match-p (rx "later") input)
           'reschedule))))

(provide 'sc-nlp)

;;; sc-nlp.el ends here
