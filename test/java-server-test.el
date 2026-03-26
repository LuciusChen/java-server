;;; java-server-test.el --- Tests for java-server -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seq)

(load "/Users/luciuschen/.emacs.d/straight/repos/dape/dape.el")
(load-file
 (expand-file-name "../java-server.el"
                   (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest java-server-hcr-uses-vm-wide-pause-and-resume ()
  (let ((requests nil)
        (events nil)
        (messages nil)
        (state 'running))
    (cl-letf (((symbol-function 'dape-request)
               (lambda (_conn command arguments &optional cb)
                 (push (list command arguments) requests)
                 (pcase command
                   (:redefineClasses
                    (when cb
                      (funcall cb '(:changedClasses ["com.example.Foo"]) nil)))
                   (:pause nil)
                   (:continue
                    (when cb
                      (funcall cb '(:allThreadsContinued t) nil))))))
              ((symbol-function 'dape--state)
               (lambda (_conn) state))
              ((symbol-function 'dape-handle-event)
               (lambda (_conn event body)
                 (push (list event body) events)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (setq java-server--pending-hcr-target-classes '("com.example.Foo")
            java-server--pending-hcr-project-details nil
            java-server--pending-hot-replace nil
            java-server--hcr-auto-resume nil
            java-server--hcr-in-progress nil)
      (java-server--request-hot-replace 'conn)
      (setq state 'stopped)
      (java-server--request-hot-replace 'conn)
      (should
       (equal (reverse requests)
              '((:pause (:threadId 0))
                (:redefineClasses nil)
                (:continue (:threadId 0)))))
      (should
       (seq-some
        (lambda (event)
          (and (eq (car event) 'continued)
               (equal (cadr event)
                      '(:threadId 0 :allThreadsContinued t))))
        events))
      (should
       (member "HCR queued; pausing all debug threads..."
               messages))
      (should
       (member "Running HCR..."
               messages)))))

(ert-deftest java-server-hcr-prefers-direct-attach-when-available ()
  (let ((messages nil)
        (called nil))
    (cl-letf (((symbol-function 'java-server--direct-hot-replace-available-p)
               (lambda (_details _targets) t))
              ((symbol-function 'java-server--direct-hot-replace)
               (lambda (_details _targets)
                 (setq called t)
                 '(:applied 1 :not-loaded 0 :synced 0)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (setq java-server--pending-hcr-target-classes '("com.example.Foo")
            java-server--pending-hcr-project-details '(:home "/tmp/example")
            java-server--pending-hot-replace nil
            java-server--hcr-auto-resume nil
            java-server--hcr-in-progress nil)
      (java-server--request-hot-replace 'conn)
      (should called)
      (should
       (member "Running direct HCR..."
               messages))
      (should
       (member "HCR applied 1 loaded classes via Attach API."
               messages))
      (should-not java-server--pending-hcr-target-classes)
      (should-not java-server--pending-hcr-project-details)
      (should-not java-server--hcr-in-progress))))

(ert-deftest java-server-gradle-class-family-files-use-build-classes ()
  (let* ((project-root (make-temp-file "java-server-gradle" t))
         (class-dir (expand-file-name "build/classes/java/main/com/example/" project-root))
         (class-file (expand-file-name "OrderServiceImpl.class" class-dir))
         (details `(:home ,project-root :build-system gradle)))
    (unwind-protect
        (progn
          (make-directory class-dir t)
          (with-temp-file class-file)
          (should
           (equal (java-server--class-family-files details "com.example.OrderServiceImpl")
                  (list class-file)))
          (should
           (equal (java-server--class-file-binary-name details class-file)
                  "com.example.OrderServiceImpl")))
      (delete-directory project-root t))))

(ert-deftest java-server-track-saved-java-class-ignores-other-project ()
  (let ((java-server--active-debug-project-details '(:home "/tmp/project-a"))
        (java-server--pending-hcr-project-details nil)
        (java-server--pending-hcr-target-classes nil))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/project-b/src/main/java/com/example/Foo.java")
      (cl-letf (((symbol-function 'java-server--active-dape-connection)
                 (lambda () 'conn))
                ((symbol-function 'derived-mode-p)
                 (lambda (&rest _modes) t))
                ((symbol-function 'java-server--detect-project)
                 (lambda (&optional _dir) '(:home "/tmp/project-b")))
                ((symbol-function 'java-server--buffer-java-primary-class)
                 (lambda () "com.example.Foo")))
        (java-server--track-saved-java-class)
        (should-not java-server--pending-hcr-project-details)
        (should-not java-server--pending-hcr-target-classes)))))

(ert-deftest java-server-direct-hcr-helper-cache-dir-uses-jdk-major-version ()
  (let* ((base-dir (make-temp-file "java-server-hcr-base" t))
         (jdk-home (make-temp-file "java-server-jdk" t))
         (release-file (expand-file-name "release" jdk-home))
         (java-server-direct-attach-hcr-helper-dir base-dir))
    (unwind-protect
        (progn
          (with-temp-file release-file
            (insert "JAVA_VERSION=\"1.8.0_301\"\n"))
          (should
           (equal (java-server--direct-hcr-helper-cache-dir jdk-home)
                  (expand-file-name "jdk-8/" base-dir)))
          (with-temp-file release-file
            (insert "JAVA_VERSION=\"17.0.10\"\n"))
          (should
           (equal (java-server--direct-hcr-helper-cache-dir jdk-home)
                  (expand-file-name "jdk-17/" base-dir))))
      (delete-directory base-dir t)
      (delete-directory jdk-home t))))

(ert-deftest java-server-hcr-does-not-reenter-while-in-progress ()
  (let ((messages nil)
        (dape-called nil)
        (direct-called nil)
        (java-server--hcr-in-progress t)
        (java-server--pending-hcr-target-classes '("com.example.Foo"))
        (java-server--pending-hcr-project-details '(:home "/tmp/example")))
    (cl-letf (((symbol-function 'dape-request)
               (lambda (&rest _args)
                 (setq dape-called t)))
              ((symbol-function 'java-server--direct-hot-replace-available-p)
               (lambda (_details _targets) t))
              ((symbol-function 'java-server--direct-hot-replace)
               (lambda (_details _targets)
                 (setq direct-called t)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (java-server--request-hot-replace 'conn)
      (should-not dape-called)
      (should-not direct-called)
      (should (member "HCR already in progress." messages)))))

;;; java-server-test.el ends here
