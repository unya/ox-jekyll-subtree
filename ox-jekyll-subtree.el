;;; ox-jekyll-subtree.el --- Extension to ox-jexkyll for better export of subtrees   -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Artur Malabarba

;; Author: Artur Malabarba <bruce.connor.am@gmail.com>
;; Keywords: hypermedia

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

;;; Commentary:
;;
;; Extension to ox-jexkyll for better export of subtrees. This is only
;; possible thanks to `ox-jekyll`, from the
;; [org-octopress](https://github.com/yoshinari-nomura/org-octopress)
;; repo (a copy is provided in this repo).
;;
;; *Please note, this is not a package, this is a script. Feel free to
;;  submit issues if you run into problems, just be aware that this does
;;  not fully conform with usual package standards.*
;;
;;; Usage
;;
;; Place this in your `load-path`, add the following lines to your init file, and invoke `M-x ojs-export-to-blog` to export a subtree as a blog post.
;;
;; ```
;; (autoload 'ojs-export-to-blog "jekyll-once")
;; (setq org-jekyll-use-src-plugin t)
;;
;; ;; Obviously, these two need to be changed for your blog.
;; (setq ojs-blog-base-url "http://endlessparentheses.com/")
;; (setq ojs-blog-dir (expand-file-name "~/Git/blog/"))
;; ```

;;; Code:

(require 'subr-x)

(defcustom ojs-blog-dir (expand-file-name "~/Git/blog/")
  "Directory to save posts."
  :type 'directory
  :group 'endless)

(defcustom ojs-blog-base-url "http://endlessparentheses.com/"
  "Base URL of the blog.
Will be stripped from link addresses on the final HTML."
  :type 'string
  :group 'endless)

(defun ojs-export-to-blog (dont-show)
  "Exports current subtree as jekyll html and copies to blog.
Posts need very little to work, most information is guessed.
Scheduled date is respected and heading is marked as DONE.

Pages are marked by a \":EXPORT_JEKYLL_LAYOUT: page\" property,
and they also need a :filename: property. Schedule is then
ignored, and the file is saved inside `ojs-blog-dir'.

The filename property is not mandatory for posts. If present, it
will used exactly (no sanitising will be done). If not, filename
will be a sanitised version of the title, see
`ojs-sanitise-file-name'."
  (interactive "P")
  (require 'org)
  (require 'ox-jekyll)
  (save-excursion
    ;; Actual posts NEED a TODO state. So we go up the tree until we
    ;; reach one.
    (while (null (org-entry-get (point) "TODO" nil t))
      (outline-up-heading 1 t))
    (org-entry-put (point) "EXPORT_JEKYLL_LAYOUT"
                   (org-entry-get (point) "EXPORT_JEKYLL_LAYOUT" t))
    ;; Try the closed stamp first to make sure we don't set the front
    ;; matter to 00:00:00 which moves the post back a day
    (let* ((closed-stamp (org-entry-get (point) "CLOSED" t))
           (date (if closed-stamp
                     (date-to-time closed-stamp)
                   (org-get-scheduled-time (point) nil)))
           (tags (nreverse (org-get-tags-at)))
           (meta-title (org-entry-get (point) "meta_title"))
           (is-page (string= (org-entry-get (point) "EXPORT_JEKYLL_LAYOUT") "page"))
           (name (org-entry-get (point) "filename"))
           (title (org-get-heading t t))
           (series (org-entry-get (point) "series" t))
           (org-jekyll-categories (mapconcat #'ojs-convert-tag tags " "))
           (org-export-show-temporary-export-buffer nil))

      (unless date
        (org-schedule nil ".")
        (setq date (current-time)))
      ;; For pages, demand filename.
      (if is-page
          (unless name (error "Pages need a :filename: property"))
        ;; For posts, guess some information that wasn't provided as
        ;; properties.
        ;; Define a name, if there isn't one.
        (unless name
          (setq name (concat (format-time-string "%Y-%m-%d" date) "-" (ojs-sanitise-file-name title)))
          (org-entry-put (point) "filename" name))
        (org-todo 'done))

      (let ((subtree-content
             (save-restriction
               (org-narrow-to-subtree)
               (ignore-errors (ispell-buffer))
               (buffer-string)))
            (header-content
             (ojs-get-org-headers))
            (reference-buffer (current-buffer)))
        (with-temp-buffer
          (ojs-prepare-input-buffer
           header-content subtree-content reference-buffer)

          ;; Export and then do some fixing on the output buffer.
          (with-current-buffer
              (org-jekyll-export-as-html nil t nil nil nil)
            (goto-char (point-min))
            ;; Configure the jekyll header.
            (search-forward "\n---\n")
            (goto-char (1+ (match-beginning 0)))
            (when series
              (insert "series: \"" series "\"\n"))
            (when meta-title
              (insert "meta_title: \"" (format meta-title title) "\"\n"))
            (search-backward-regexp "\ndate *:\\(.*\\)$")
            (if is-page
                ;; Pages don't need a date field.
                (replace-match "" :fixedcase :literal nil 0)
              (replace-match (concat " " (format-time-string "%Y-%m-%d %T" date)) :fixedcase :literal nil 1))

            ;; Save the final file.
            (ojs-clean-output-links)
            (let ((out-file
                   (expand-file-name (concat (if is-page "" "_posts/") name ".html")
                                     ojs-blog-dir)))
              (write-file out-file)
              (unless dont-show
                (find-file-other-window out-file)))

            ;; In case we commit, lets push the message to the kill-ring
            (kill-new (concat "UPDATE: " title))
            (kill-new (concat "POST: " title))))))))

(defun ojs-get-org-headers ()
  "Return everything above the first headline of current buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward-regexp "^\\*+ ")
    (buffer-substring-no-properties (point-min) (match-beginning 0))))

(defvar ojs-base-regexp
  (macroexpand `(rx (or ,ojs-blog-base-url ,ojs-blog-dir)))
  "")

(defun ojs-clean-output-links ()
  "Strip `ojs-blog-base-url' and \"file://\" from the start of URLs. "
  ;; Fix org's stupid filename handling.
  (goto-char (point-min))
  (while (search-forward-regexp "\\(href\\|src\\)=\"\\(file://\\)/" nil t)
    (replace-match "" :fixedcase :literal nil 2))
  ;; Strip base-url from links
  (goto-char (point-min))
  (while (search-forward-regexp
          (concat "href=\"" ojs-base-regexp)
          nil t)
    (replace-match "href=\"/" :fixedcase :literal))
  (goto-char (point-min)))

(defun ojs-prepare-input-buffer (header content reference-buffer)
  "Insert content and clean it up a bit."
  (insert header content)
  (goto-char (point-min))
  (org-mode)
  (outline-next-heading)
  (let ((this-filename (org-entry-get nil "filename" t))
        target-filename)
    (while (progn (org-next-link)
                  (not org-link--search-failed))
      (cond
       ((looking-at (format "\\[\\[\\(file:%s\\)"
                            (regexp-quote (abbreviate-file-name ojs-blog-dir))))
        (replace-match "file:/" nil nil nil 1)
        (goto-char (match-beginning 0))
        (when (looking-at (rx "[[" (group "file:/images/" (+ (not space))) "]]"))
          (goto-char (match-end 1))
          (forward-char 1)
          (insert "[" (match-string 1) "]")
          (forward-char 1)))
       ((looking-at "\\[\\[\\(\\*[^]]+\\)\\]")
        ;; Find the blog post to which this link points.
        (setq target-filename
              (save-excursion
                (save-match-data
                  (let ((point (with-current-buffer reference-buffer
                                 (point))))
                    (org-open-at-point t reference-buffer)
                    (with-current-buffer reference-buffer
                      (prog1 (url-hexify-string (org-entry-get nil "filename" t))
                        (goto-char point)))))))
        ;; We don't want to replace links inside the same post. Org
        ;; handles them better than us.
        (when (and target-filename
                   (null (string= target-filename this-filename)))
          (replace-match
           (format "/%s.html" (ojs-strip-date-from-filename target-filename))
           :fixedcase :literal nil 1))))))
  (goto-char (point-min))
  (outline-next-heading))

(defun ojs-strip-date-from-filename (name)
  (replace-regexp-in-string "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-" "" name))

(defun ojs-convert-tag (tag)
  "Overcome org-mode's tag limitations."
  (replace-regexp-in-string
   "_" "-"
   (replace-regexp-in-string "__" "." tag)))

(defun ojs-sanitise-file-name (name)
  "Make NAME safe for filenames.
Removes any occurrence of parentheses (with their content),
Trims the result,
And transforms anything that's not alphanumeric into dashes."
  (require 'url-util)
  (require 'subr-x)
  (url-hexify-string
   (downcase
    (replace-regexp-in-string
     "[^[:alnum:]]+" "-"
     (string-trim
      (replace-regexp-in-string
       "(.*)" "" name))))))

(provide 'ox-jekyll-subtree)
;;; ox-jekyll-subtree.el ends here
