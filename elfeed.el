;;; elfeed.el --- an Emacs web feed reader -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Author: Christopher Wellons <wellons@nullprogram.com>
;; URL: https://github.com/skeeto/elfeed
;; Version: 1.0.0
;; Package-Requires: ((emacs "24.1"))

;;; Commentary:

;; Elfreed is a web feed client for Emacs, inspired by notmuch. See
;; the README for full documentation.

;; Elfreed requires Emacs 24 (lexical closures).

;;; Code:

(require 'cl)
(require 'xml)
(require 'xml-query)
(require 'url-parse)

(defgroup elfeed nil
  "An Emacs web feed reader."
  :group 'comm)

(defcustom elfeed-feeds ()
  "List of all feeds that elfeed should follow. You must add your
feeds to this list."
  :group 'elfeed
  :type 'list)

(provide 'elfeed)

(require 'elfeed-search)
(require 'elfeed-lib)
(require 'elfeed-db)

(defcustom elfeed-initial-tags '(unread)
  "Initial tags for new entries."
  :group 'elfeed
  :type 'list)

;; Fetching:

(defcustom elfeed-max-connections
  ;; Windows Emacs cannot open many sockets at once.
  (if (eq system-type 'windows-nt) 1 4)
  "The maximum number of feeds to be fetched in parallel."
  :group 'elfeed
  :type 'integer)

(defvar elfeed-connections nil
  "List of callbacks awaiting responses.")

(defvar elfeed-waiting nil
  "List of requests awaiting connections.")

(defvar elfeed--connection-counter 0
  "Provides unique connection identifiers.")

(defun elfeed--check-queue ()
  "Start waiting connections if connection slots are available."
  (while (and elfeed-waiting
              (< (length elfeed-connections) elfeed-max-connections))
    (let ((request (pop elfeed-waiting)))
      (destructuring-bind (_ url cb) request
        (push request elfeed-connections)
        (condition-case error
            (url-retrieve url cb)
          (error (with-temp-buffer (funcall cb (list :error error)))))))))

(defun elfeed--wrap-callback (id cb)
  "Return a function that manages the elfeed queue."
  (lambda (status)
    (unwind-protect
        (funcall cb status)
      (setf elfeed-connections (delete* id elfeed-connections :key #'car))
      (elfeed--check-queue))))

(defun elfeed-fetch (url callback)
  "Basically wraps `url-retrieve' but uses the connection limiter."
  (let* ((id (incf elfeed--connection-counter))
         (cb (elfeed--wrap-callback id callback)))
    (push (list id url cb) elfeed-waiting)
    (elfeed--check-queue)))

(defmacro with-elfeed-fetch (url &rest body)
  "Asynchronously run BODY in a buffer with the contents from
URL. This macro is anaphoric, with STATUS referring to the status
from `url-retrieve'."
  (declare (indent defun))
  `(elfeed-fetch ,url (lambda (status) ,@body (kill-buffer))))

;; Parsing:

(defun elfeed-feed-type (content)
  "Return the feed type given the parsed content (:atom, :rss) or
NIL for unknown."
  (cadr (assoc (caar content) '((feed :atom) (rss :rss)))))

(defun elfeed-float-time (&optional date)
  "Like `float-time' but accept anything reasonable for DATE,
defaulting to the current time if DATE could not be parsed. Date
is allowed to be relative to now (`elfeed-time-duration')."
  (typecase date
    (string
     (let ((duration (elfeed-time-duration date)))
       (if duration
           (- (float-time) duration)
         (let ((time (ignore-errors (date-to-time date))))
           (if (equal time '(14445 17280)) ; date-to-time silently failed
               (float-time)
             (float-time time))))))
    (integer date)
    (list (float-time date))
    (t (float-time))))

(defun elfeed-cleanup (name)
  "Cleanup things that will be printed."
  (let ((trim (replace-regexp-in-string "[\n\t]+" " " (or name ""))))
    (replace-regexp-in-string "^ +\\| +$" "" trim)))

(defun elfeed-entries-from-atom (url xml)
  "Turn parsed Atom content into a list of elfeed-entry structs."
  (let* ((feed-id url)
         (feed (elfeed-db-get-feed feed-id))
         (title (xml-query '(feed title *) xml)))
    (setf (elfeed-feed-url feed) url
          (elfeed-feed-title feed) title)
    (loop for entry in (xml-query-all '(feed entry) xml) collect
          (let* ((title (or (xml-query '(title *) entry) ""))
                 (anylink (xml-query '(link :href) entry))
                 (altlink (xml-query '(link [rel "alternate"] :href) entry))
                 (link (or altlink anylink))
                 (id (or (xml-query '(id *) entry) link))
                 (date (or (xml-query '(published *) entry)
                           (xml-query '(updated *) entry)
                           (xml-query '(date *) entry)))
                 (content (or (xml-query '(content *) entry)
                              (xml-query '(summary *) entry)))
                 (type (or (xml-query '(content :type) entry)
                           (xml-query '(summary :type) entry)
                           ""))
                 (etags (xml-query-all '(link [rel "enclosure"]) entry))
                 (enclosures (loop for enclosure in etags
                                   for wrap = (list enclosure)
                                   for href = (xml-query '(:href) wrap)
                                   for type = (xml-query '(:type) wrap)
                                   for length = (xml-query '(:length) wrap)
                                   collect (list href type length))))
            (make-elfeed-entry :title (elfeed-cleanup title) :feed-id feed-id
                               :id (cons feed-id (elfeed-cleanup id))
                               :link link :tags (copy-seq elfeed-initial-tags)
                               :date (elfeed-float-time date) :content content
                               :enclosures enclosures
                               :content-type (if (string-match-p "html" type)
                                                 'html
                                               nil))))))

(defun elfeed-entries-from-rss (url xml)
  "Turn parsed RSS content into a list of elfeed-entry structs."
  (let* ((feed-id url)
         (feed (elfeed-db-get-feed feed-id))
         (title (xml-query '(rss channel title *) xml)))
    (setf (elfeed-feed-url feed) url
          (elfeed-feed-title feed) title)
    (loop for item in (xml-query-all '(rss channel item) xml) collect
          (let* ((title (or (xml-query '(title *) item) ""))
                 (link (xml-query '(link *) item))
                 (guid (xml-query '(guid *) item))
                 (id (or guid link))
                 (date (or (xml-query '(pubDate *) item)
                           (xml-query '(date *) item)))
                 (description (xml-query '(description *) item))
                 (etags (xml-query-all '(enclosure) item))
                 (enclosures (loop for enclosure in etags
                                   for wrap = (list enclosure)
                                   for url = (xml-query '(:url) wrap)
                                   for type = (xml-query '(:type) wrap)
                                   for length = (xml-query '(:length) wrap)
                                   collect (list url type length))))
            (make-elfeed-entry :title (elfeed-cleanup title)
                               :id (cons feed-id (elfeed-cleanup id))
                               :feed-id feed-id :link link
                               :tags (copy-seq elfeed-initial-tags)
                               :date (elfeed-float-time date)
                               :enclosures enclosures
                               :content description :content-type 'html)))))

(defun elfeed-update-feed (url)
  "Update a specific feed."
  (interactive (list (completing-read "Feed: " elfeed-feeds)))
  (with-elfeed-fetch url
    (if (and status (eq (car status) :error))
        (message "Elfeed update failed for %s: %s" url status)
      (condition-case error
          (progn
            (goto-char (point-min))
            (search-forward "\n\n") ; skip HTTP headers
            (set-buffer-multibyte t)
            (let* ((xml (xml-parse-region (point) (point-max)))
                   (entries (case (elfeed-feed-type xml)
                              (:atom (elfeed-entries-from-atom url xml))
                              (:rss (elfeed-entries-from-rss url xml))
                              (t (error "Unknown feed type.")))))
              (elfeed-db-add entries)))
        (error (message "Elfeed update failed for %s: %s" url error))))))

(defun elfeed-add-feed (url)
  "Manually add a feed to the database."
  (interactive (list
                (let ((clipboard (x-get-selection-value)))
                  (read-from-minibuffer
                   "URL: " (if (elfeed-looks-like-url-p clipboard)
                               clipboard)))))
  (pushnew url elfeed-feeds :test #'string=)
  (elfeed-update-feed url))

;;;###autoload
(defun elfeed-update ()
  "Update all the feeds in `elfeed-feeds'."
  (interactive)
  (mapc #'elfeed-update-feed elfeed-feeds)
  (elfeed-db-save))

;;;###autoload
(defun elfeed ()
  "Enter elfeed."
  (interactive)
  (switch-to-buffer (elfeed-search-buffer))
  (unless (eq major-mode 'elfeed-search-mode)
    (elfeed-search-mode))
  (elfeed-search-update))

;; New entry filtering

(defun* elfeed-make-tagger
    (&key feed-title feed-url entry-title entry-link after before
          add remove callback)
  "Create a function that adds or removes tags on matching entries.

FEED-TITLE, FEED-URL, ENTRY-TITLE, and ENTRY-LINK are regular
expressions or a list (not <regex>), which indicates a negative
match. AFTER and BEFORE are relative times (see
`elfeed-time-duration'). Entries must match all provided
expressions. If an entry matches, add tags ADD and remove tags
REMOVE.

Examples,

  (elfeed-make-tagger :feed-url \"youtube\\\\.com\"
                      :add '(video youtube))

  (elfeed-make-tagger :before \"1 week ago\"
                      :remove 'unread)

  (elfeed-make-tagger :feed-url \"example\\\\.com\"
                      :entry-title '(not \"something interesting\")
                      :add 'junk)

The returned function should be added to `elfeed-new-entry-hook'."
  (let ((after-time  (and after  (elfeed-time-duration after)))
        (before-time (and before (elfeed-time-duration before))))
    (when (and add (symbolp add)) (setf add (list add)))
    (when (and remove (symbolp remove)) (setf remove (list remove)))
    (lambda (entry)
      (let ((feed (elfeed-entry-feed entry))
            (date (elfeed-entry-date entry))
            (case-fold-search t))
        (cl-flet ((match (r s)
                         (or (null r)
                             (if (listp r)
                                 (not (string-match-p (second r) s))
                               (string-match-p r s)))))
          (when (and
                 (match feed-title  (elfeed-feed-title  feed))
                 (match feed-url    (elfeed-feed-url    feed))
                 (match entry-title (elfeed-entry-title entry))
                 (match entry-link  (elfeed-entry-link  entry))
                 (or (not after-time)  (> date (- (float-time) after-time)))
                 (or (not before-time) (< date (- (float-time) before-time))))
            (when add
              (apply #'elfeed-tag entry add))
            (when remove
              (apply #'elfeed-untag entry remove))
            (when callback
              (funcall callback entry))
            entry))))))

;;; elfeed.el ends here
