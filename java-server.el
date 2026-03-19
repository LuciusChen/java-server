;;; java-server.el --- Java development utilities for Emacs -*- lexical-binding: t -*-
;;
;; Author:
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: java, tools, languages
;; URL:
;;
;; This file is NOT part of GNU Emacs.
;;
;;; Commentary:
;;
;; Provides:
;;   * Multi-JDK switching (auto-detect from pom.xml)
;;   * Tomcat WAR build-and-deploy with mode-line status
;;   * Spring Boot JAR build-and-run with mode-line status
;;   * Optional dape integration (auto-attach on debug start)
;;   * MyBatis mapper <-> XML navigation
;;   * .class file decompilation via FernFlower
;;
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'xref)

(declare-function eglot-current-server "eglot")
(declare-function eglot-execute-command "eglot")
(declare-function dape "dape")
(declare-function notifications-notify "notifications")

;;; ============================================================
;;; Module 1: Customization
;;; ============================================================

(defgroup java-server nil
  "Java development utilities."
  :group 'tools
  :prefix "java-server-")

(defcustom java-server-tomcat-port 8080
  "The port number that Tomcat server listens on."
  :type 'natnum
  :group 'java-server)

(defcustom java-server-tomcat-debug-port 8000
  "JPDA debug port for Tomcat."
  :type 'natnum
  :group 'java-server)

(defcustom java-server-spring-boot-port 8080
  "The port number that Spring Boot application listens on."
  :type 'natnum
  :group 'java-server)

(defcustom java-server-spring-boot-debug-port 5005
  "JPDA debug port for Spring Boot."
  :type 'natnum
  :group 'java-server)

(defcustom java-server-debug-adapters-dir
  (expand-file-name "debug-adapters" user-emacs-directory)
  "Directory containing debug adapter JARs."
  :type 'directory
  :group 'java-server)

(defcustom java-server-auto-dape-on-debug t
  "Whether to automatically invoke dape after debug server is ready."
  :type 'boolean
  :group 'java-server)


;;; ============================================================
;;; Module 2: Project detection
;;; ============================================================

(defun java-server--detect-build-system (dir)
  "Detect build system in DIR."
  (cond
   ((file-exists-p (expand-file-name "pom.xml" dir)) 'maven)
   ((or (file-exists-p (expand-file-name "build.gradle" dir))
        (file-exists-p (expand-file-name "build.gradle.kts" dir)))
    'gradle)))

(defun java-server--detect-project (&optional dir)
  "Detect project home, name, and build system from DIR.
Return a plist (:name STRING :home STRING :build-system SYMBOL)."
  (let* ((base-dir (or dir
                       (and (buffer-file-name)
                            (file-name-directory (buffer-file-name)))
                       default-directory))
         (project (and base-dir (project-current nil base-dir)))
         (home (or (and project (project-root project))
                   (and base-dir
                        (locate-dominating-file
                         base-dir
                         (lambda (d)
                           (or (file-exists-p (expand-file-name "pom.xml" d))
                               (file-directory-p (expand-file-name ".git" d))
                               (file-exists-p (expand-file-name "build.gradle" d))
                               (file-exists-p (expand-file-name "build.gradle.kts" d))
                               (file-exists-p (expand-file-name "settings.gradle" d))
                               (file-exists-p (expand-file-name "settings.gradle.kts" d))))))))
         (home (and home (directory-file-name (expand-file-name home))))
         (name (or (and project (project-name project))
                   (and home (file-name-nondirectory home)))))
    (unless (and home name)
      (user-error "Could not determine the project root"))
    (list :name name
          :home home
          :build-system (java-server--detect-build-system home))))

(defun java-server--port-open-p (host port)
  "Return non-nil if PORT on HOST is open."
  (condition-case nil
      (let ((proc (make-network-process
                   :name "java-server-check-port"
                   :host host :service port
                   :nowait nil)))
        (when proc (delete-process proc) t))
    (error nil)))

;;; ============================================================
;;; Module 3: Multi-JDK management
;;; ============================================================

(defun java-server--maven-detect-jdk-version ()
  "Detect JDK version from Maven POM file.
Return version string (e.g. \"1.8\" or \"17\")."
  (when-let* ((details (java-server--detect-project))
              (pom (expand-file-name "pom.xml" (plist-get details :home)))
              (content (when (file-exists-p pom)
                         (with-temp-buffer
                           (insert-file-contents pom)
                           (buffer-string)))))
    (or (when (string-match "<maven.compiler.release>\\([^<]+\\)</maven.compiler.release>" content)
          (match-string 1 content))
        (when (string-match "<maven.compiler.source>\\([^<]+\\)</maven.compiler.source>" content)
          (match-string 1 content))
        (when (string-match "<source>\\([^<]+\\)</source>" content)
          (match-string 1 content)))))

(defun java-server--normalize-jdk-version (version)
  "Normalize Maven JDK VERSION string to plain major version.
E.g. \"1.8\" -> \"8\", \"11\" -> \"11\"."
  (if (string-match "^1\\.\\([0-9]+\\)$" version)
      (match-string 1 version)
    version))

(defun java-server--list-jdk-homes ()
  "Return a list of available JDK home paths."
  (cond
   ((eq system-type 'darwin)
    (seq-filter
     (lambda (path)
       (not (string-match-p "JavaAppletPlugin.plugin" path)))
     (split-string
      (shell-command-to-string
       "/usr/libexec/java_home -V 2>&1 | grep '/Library' | awk '{print $NF}'")
      "\n" t)))
   ((eq system-type 'gnu/linux)
    (seq-filter
     (lambda (path)
       (not (string-match-p "/default" path)))
     (split-string
      (shell-command-to-string "ls -d /usr/lib/jvm/*/ 2>/dev/null")
      "\n" t)))
   (t
    (user-error "Unsupported system: %s" system-type))))

(defun java-server--set-java-home (choice)
  "Set global JAVA_HOME to CHOICE and update PATH accordingly."
  (setenv "JAVA_HOME" choice)
  (let* ((java-bin (directory-file-name (expand-file-name "bin/" choice)))
         (path-list (split-string (or (getenv "PATH") "") path-separator t))
         (path-list (seq-remove
                     (lambda (p)
                       (string= (directory-file-name (expand-file-name p))
                                java-bin))
                     path-list)))
    (setenv "PATH" (mapconcat #'identity (cons java-bin path-list) path-separator))))

(defun java-server--process-environment-for-jdk (jdk-home)
  "Return a `process-environment' list with JAVA_HOME set to JDK-HOME.
The returned list is suitable for `let'-binding around subprocess calls,
leaving the global environment untouched."
  (let* ((java-bin (directory-file-name (expand-file-name "bin/" jdk-home)))
         (path-list (split-string (or (getenv "PATH") "") path-separator t))
         (path-list (seq-remove
                     (lambda (p)
                       (string= (directory-file-name (expand-file-name p))
                                java-bin))
                     path-list))
         (new-path (mapconcat #'identity (cons java-bin path-list) path-separator)))
    (cons (concat "JAVA_HOME=" jdk-home)
          (cons (concat "PATH=" new-path)
                (seq-remove
                 (lambda (e)
                   (or (string-prefix-p "JAVA_HOME=" e)
                       (string-prefix-p "PATH=" e)))
                 process-environment)))))

(defun java-server--resolve-project-jdk ()
  "Detect the JDK needed by the current project from pom.xml.
Return the matching JDK home path, or nil if the project uses
the same version as the current global JAVA_HOME."
  (when-let* ((version-raw (java-server--maven-detect-jdk-version))
              (version (java-server--normalize-jdk-version version-raw))
              ;; If global JAVA_HOME already matches, no override needed
              (_ (not (and (getenv "JAVA_HOME")
                                   (string-match-p (regexp-quote version)
                                                   (getenv "JAVA_HOME")))))
              (candidates (java-server--list-jdk-homes))
              (match (seq-find (lambda (path)
                                 (string-match-p (regexp-quote version) path))
                               candidates)))
    match))

;;;###autoload
(defun java-server-select-jdk ()
  "List all available JDK home paths and let the user choose one.
Set JAVA_HOME and update PATH accordingly."
  (interactive)
  (let* ((candidates (java-server--list-jdk-homes))
         (choice (completing-read "Select JAVA_HOME: " candidates nil t)))
    (java-server--set-java-home choice)
    (message "JAVA_HOME set to %s" choice)))

;;;###autoload
(defun java-server-auto-select-jdk (&rest _)
  "Auto-select JAVA_HOME based on Maven POM JDK version.
If no matching version is found, prompt the user to choose."
  (interactive)
  (let* ((jdk-version-raw (java-server--maven-detect-jdk-version))
         (jdk-version (and jdk-version-raw
                           (java-server--normalize-jdk-version jdk-version-raw)))
         (candidates (java-server--list-jdk-homes))
         (match (and jdk-version
                     (seq-find (lambda (path)
                                 (string-match-p (regexp-quote jdk-version) path))
                               candidates)))
         (choice (or match
                     (completing-read
                      (if jdk-version
                          (format "No JDK %s found, select manually: " jdk-version)
                        "Select JAVA_HOME: ")
                      candidates nil t))))
    (when choice
      (java-server--set-java-home choice)
      (message "JAVA_HOME set to %s%s"
               choice
               (if jdk-version
                   (format " (from pom.xml JDK version %s)" jdk-version)
                 "")))))

;;; ============================================================
;;; Module 4: Tomcat management
;;; ============================================================

(defvar java-server--tomcat-status nil
  "Current Tomcat server status: nil, `starting', `running', or `failed'.")

(defvar java-server--tomcat-mode-line nil
  "Mode-line string for Tomcat status.")
(put 'java-server--tomcat-mode-line 'risky-local-variable t)

(defun java-server--ensure-mode-line (entry)
  "Ensure ENTRY is in `global-mode-string'."
  (unless (member entry global-mode-string)
    (add-to-list 'global-mode-string entry t)))

(defun java-server--remove-mode-line (entry)
  "Remove ENTRY from `global-mode-string'."
  (setq global-mode-string (delete entry global-mode-string)))

(defvar java-server--tomcat-mode-line-entry '("" java-server--tomcat-mode-line)
  "Entry for `global-mode-string'.")

(defun java-server--tomcat-set-status (status)
  "Set Tomcat status to STATUS and refresh mode line."
  (setq java-server--tomcat-status status
        java-server--tomcat-mode-line
        (pcase status
          ('starting
           (propertize " Tomcat starting..." 'face 'warning))
          ('running
           (propertize (format " Tomcat: %d" java-server-tomcat-port) 'face 'success))
          ('failed
           (propertize " Tomcat failed" 'face 'error))
          (_ nil)))
  (if status
      (java-server--ensure-mode-line java-server--tomcat-mode-line-entry)
    (java-server--remove-mode-line java-server--tomcat-mode-line-entry))
  (force-mode-line-update t))

(defun java-server--notify (title body)
  "Send a desktop notification with TITLE and BODY.
Falls back silently if unavailable."
  (condition-case nil
      (cond
       ((eq system-type 'gnu/linux)
        (notifications-notify :title title :body body :urgency 'normal))
       ((eq system-type 'darwin)
        (start-process "java-server-notify" nil
                       "osascript" "-e"
                       (format "display notification %S with title %S"
                               body title))))
    (error nil)))

(defun java-server--tomcat-notify-ready (debug)
  "Send a desktop notification that Tomcat is ready.
DEBUG indicates JPDA mode."
  (java-server--notify
   "Tomcat"
   (format "Server ready%s -> http://localhost:%d"
           (if debug (format " [JPDA :%d]" java-server-tomcat-debug-port) "")
           java-server-tomcat-port)))

(defun java-server--detect-tomcat-home ()
  "Return TOMCAT_HOME path."
  (string-trim
   (shell-command-to-string
    (concat
     "( if command -v brew >/dev/null 2>&1; then\n"
     "    prefix=$(brew --prefix tomcat@9 2>/dev/null || brew --prefix tomcat 2>/dev/null);\n"
     "    if [ -n \"$prefix\" ]; then\n"
     "        echo \"$prefix/libexec\";\n"
     "    elif [ -d \"$HOME/tomcat10\" ]; then\n"
     "        echo \"$HOME/tomcat10\";\n"
     "    elif [ -d \"$HOME/tomcat9\" ]; then\n"
     "        echo \"$HOME/tomcat9\";\n"
     "    fi;\n"
     "elif [ -d \"$HOME/tomcat10\" ]; then\n"
     "    echo \"$HOME/tomcat10\";\n"
     "elif [ -d \"$HOME/tomcat9\" ]; then\n"
     "    echo \"$HOME/tomcat9\";\n"
     "fi )"))))

(defun java-server--tomcat-get-pid ()
  "Return Tomcat PID string if running, else nil."
  (let ((pid (string-trim
              (shell-command-to-string
               "pgrep -f 'org.apache.catalina.startup.Bootstrap'"))))
    (unless (string-empty-p pid) pid)))

(defun java-server--tomcat-startup-filter (debug)
  "Return a process filter that detects Tomcat startup.
DEBUG non-nil means JPDA mode is active."
  (let ((notified nil)
        (line-count 0)
        (call-count 0))
    (lambda (proc output)
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert output)
            (cl-incf line-count (cl-count ?\n output))
            (cl-incf call-count)
            (when (and (zerop (mod call-count 50))
                       (> line-count 5000))
              (goto-char (point-min))
              (forward-line (- line-count 5000))
              (delete-region (point-min) (point))
              (setq line-count 5000)))))
      (when (and (not notified)
                 (string-match-p "Server startup in" output))
        (setq notified t)
        (java-server--tomcat-set-status 'running)
        (java-server--tomcat-notify-ready debug)
        (message "Tomcat ready%s -> http://localhost:%d"
                 (if debug (format " [JPDA :%d]" java-server-tomcat-debug-port) "")
                 java-server-tomcat-port)
        (when (and debug java-server-auto-dape-on-debug)
          (java-server--dape-attach java-server-tomcat-debug-port))))))

(defun java-server--tomcat-do-start (proc-name buf-name start-cmd debug)
  "Start Tomcat process PROC-NAME in BUF-NAME using START-CMD.
DEBUG non-nil means JPDA mode."
  (message "Starting Tomcat%s..." (if debug " with JPDA" ""))
  (java-server--tomcat-set-status 'starting)
  (let ((proc (start-process-shell-command proc-name buf-name start-cmd)))
    (set-process-filter proc (java-server--tomcat-startup-filter debug))
    (set-process-sentinel
     proc
     (lambda (_proc event)
       (when (string-match-p
              (rx (or "finished" "exited" "failed" "killed"))
              event)
         (java-server--tomcat-set-status nil))))))

(defun java-server--tomcat-wait-then-start (proc-name buf-name start-cmd debug remaining env)
  "Poll until Tomcat port closes, then start.
Retry every second up to REMAINING times.
ENV is the `process-environment' to use for the subprocess."
  (cond
   ((not (java-server--port-open-p "localhost" java-server-tomcat-port))
    (let ((process-environment env))
      (java-server--tomcat-do-start proc-name buf-name start-cmd debug)))
   ((> remaining 0)
    (run-with-timer 1 nil #'java-server--tomcat-wait-then-start
                    proc-name buf-name start-cmd debug (1- remaining) env))
   (t
    (message "Tomcat did not stop within timeout. Aborting deploy."))))

(defun java-server--find-war (project-home)
  "Find the WAR file in PROJECT-HOME/target/.
Return the path to the first .war file found, or nil."
  (when-let* ((target-dir (expand-file-name "target/" project-home))
              (_ (file-directory-p target-dir))
              (wars (directory-files target-dir t "\\.war$")))
    (car wars)))

(defun java-server--tomcat-replace-war (webapps-path war-file)
  "Remove old WAR and exploded dir matching WAR-FILE, then copy into WEBAPPS-PATH."
  (let ((base-name (file-name-sans-extension (file-name-nondirectory war-file))))
    (ignore-errors (delete-file (concat webapps-path base-name ".war")))
    (ignore-errors (delete-directory (concat webapps-path base-name) t))
    (copy-file war-file webapps-path t)))

(defun java-server--tomcat-catalina-cmd (tomcat-home debug)
  "Return the catalina.sh command string for TOMCAT-HOME.
DEBUG non-nil enables JPDA."
  (let ((script (shell-quote-argument (concat tomcat-home "/bin/catalina.sh"))))
    (if debug
        (format "CATALINA_OPTS='-agentlib:jdwp=transport=dt_socket,address=%d,server=y,suspend=n' %s run"
                java-server-tomcat-debug-port script)
      (concat script " run"))))

(defun java-server--tomcat-deploy-war (debug &optional project-details)
  "Copy the WAR file to Tomcat webapps and manage Tomcat.
DEBUG non-nil enables JPDA debugging.
PROJECT-DETAILS is an optional plist from `java-server--detect-project'.
Uses project-specific JDK if detected, without changing global JAVA_HOME."
  (let* ((tomcat-home (or (java-server--detect-tomcat-home)
                          (user-error "Unable to detect Tomcat home directory")))
         (details (or project-details (java-server--detect-project)))
         (project-home (plist-get details :home))
         (project-jdk (java-server--resolve-project-jdk))
         (process-environment (if project-jdk
                                  (java-server--process-environment-for-jdk project-jdk)
                                process-environment))
         (webapps-path (concat tomcat-home "/webapps/"))
         (war-file (or (java-server--find-war project-home)
                       (user-error "No WAR file found in %s/target/" project-home)))
         (startup-command (java-server--tomcat-catalina-cmd tomcat-home debug)))
    (java-server--tomcat-replace-war webapps-path war-file)
    (let ((buf-name (if debug "*tomcat-debug*" "*tomcat-start*"))
          (proc-name (if debug "tomcat-debug" "tomcat-start")))
      (if (java-server--port-open-p "localhost" java-server-tomcat-port)
          (progn
            (java-server-tomcat-stop)
            (java-server--tomcat-wait-then-start
             proc-name buf-name startup-command debug 30 process-environment))
        (java-server--tomcat-do-start proc-name buf-name startup-command debug)))))

;;;###autoload
(defun java-server-tomcat-stop ()
  "Safely shutdown Tomcat.
Try catalina.sh stop first, wait 2s, then kill process group if needed."
  (interactive)
  (let* ((home (or (java-server--detect-tomcat-home)
                   (user-error "Unable to detect Tomcat home directory")))
         (catalina-script (expand-file-name "bin/catalina.sh" home))
         (pid (java-server--tomcat-get-pid)))
    (unless (file-exists-p catalina-script)
      (user-error "catalina.sh not found at %s" catalina-script))
    (if (not pid)
        (message ">>> No Tomcat process found.")
      (java-server--tomcat-set-status nil)
      (message ">>> Trying catalina.sh stop...")
      (start-process-shell-command "tomcat-stop" "*tomcat-stop*"
                                   (concat (shell-quote-argument catalina-script) " stop"))
      (sleep-for 2)
      (if (not (java-server--tomcat-get-pid))
          (message ">>> Tomcat stopped gracefully.")
        (java-server--tomcat-force-kill pid)))))

(defun java-server--tomcat-force-kill (pid)
  "Force kill Tomcat by process group of PID."
  (let ((pgid (string-trim
               (with-output-to-string
                 (with-current-buffer standard-output
                   (call-process "ps" nil t nil "-o" "pgid=" "-p" pid))))))
    (message ">>> Tomcat still running, killing process group %s..." pgid)
    (java-server--kill-process-group pgid "TERM")
    (sleep-for 1)
    (when (java-server--tomcat-get-pid)
      (java-server--kill-process-group pgid "9"))
    (if (java-server--tomcat-get-pid)
        (message ">>> Failed to stop Tomcat.")
      (message ">>> Tomcat force killed."))))

(defun java-server--kill-process-group (pgid signal)
  "Send SIGNAL to process group PGID."
  (if (eq system-type 'darwin)
      (call-process "kill" nil nil nil (concat "-" signal) (concat "-" pgid))
    (call-process "kill" nil nil nil (concat "-" signal) "--" (concat "-" pgid))))

;;;###autoload
(defun java-server-tomcat-deploy (debug)
  "Build with Maven then deploy WAR to Tomcat.
With prefix argument DEBUG, enable JPDA remote debugging.
Automatically detects the JDK version from pom.xml and uses it
for the build subprocess without changing the global JAVA_HOME."
  (interactive "P")
  (let* ((details (java-server--detect-project))
         (home (plist-get details :home))
         (project-jdk (java-server--resolve-project-jdk))
         (process-environment (if project-jdk
                                  (java-server--process-environment-for-jdk project-jdk)
                                process-environment))
         (build-buf "*tomcat-mvn-build*")
         (cmd (format "cd %s && mvn package -DskipTests"
                      (shell-quote-argument (directory-file-name home)))))
    (when project-jdk
      (message "Using project JDK: %s" project-jdk))
    (message "Building project (mvn package -DskipTests)...")
    (set-process-sentinel
     (start-process-shell-command "tomcat-mvn-build" build-buf cmd)
     (let ((captured-details details)
           (captured-debug debug))
       (lambda (proc _event)
         (if (= 0 (process-exit-status proc))
             (progn
               (message "Build succeeded. Deploying to Tomcat...")
               (java-server--tomcat-deploy-war captured-debug captured-details))
           (message "Maven build FAILED. See %s for details." build-buf)))))))

;;; ============================================================
;;; Module 5: Spring Boot management
;;; ============================================================

(defvar java-server--spring-boot-process nil
  "The running Spring Boot process object.")

(defvar java-server--spring-boot-status nil
  "Current Spring Boot status: nil, `starting', `running', or `failed'.")

(defvar java-server--spring-boot-mode-line nil
  "Mode-line string for Spring Boot status.")
(put 'java-server--spring-boot-mode-line 'risky-local-variable t)

(defvar java-server--spring-boot-mode-line-entry '("" java-server--spring-boot-mode-line)
  "Entry for `global-mode-string'.")

(defun java-server--spring-boot-set-status (status)
  "Set Spring Boot status to STATUS and refresh mode line."
  (setq java-server--spring-boot-status status
        java-server--spring-boot-mode-line
        (pcase status
          ('starting
           (propertize " Boot starting..." 'face 'warning))
          ('running
           (propertize (format " Boot: %d" java-server-spring-boot-port) 'face 'success))
          ('failed
           (propertize " Boot failed" 'face 'error))
          (_ nil)))
  (if status
      (java-server--ensure-mode-line java-server--spring-boot-mode-line-entry)
    (java-server--remove-mode-line java-server--spring-boot-mode-line-entry))
  (force-mode-line-update t))

(defun java-server--spring-boot-find-jar (project-home)
  "Find the Spring Boot JAR in PROJECT-HOME.
Search Maven (target/) and Gradle (build/libs/) output directories.
Exclude files containing \"-original\" or \"-plain\"."
  (let ((candidates (append
                     (java-server--find-jars-in-dir
                      (expand-file-name "target/" project-home))
                     (java-server--find-jars-in-dir
                      (expand-file-name "build/libs/" project-home)))))
    (car candidates)))

(defun java-server--find-jars-in-dir (dir)
  "Return JAR files in DIR, excluding -original and -plain variants."
  (when (file-directory-p dir)
    (seq-filter
     (lambda (f)
       (let ((name (file-name-nondirectory f)))
         (not (or (string-match-p "-original" name)
                  (string-match-p "-plain" name)))))
     (directory-files dir t "\\.jar$"))))

(defun java-server--spring-boot-startup-filter (debug)
  "Return a process filter that detects Spring Boot startup.
DEBUG non-nil means JPDA is active."
  (let ((notified nil)
        (line-count 0)
        (call-count 0))
    (lambda (proc output)
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert output)
            (cl-incf line-count (cl-count ?\n output))
            (cl-incf call-count)
            (when (and (zerop (mod call-count 50))
                       (> line-count 5000))
              (goto-char (point-min))
              (forward-line (- line-count 5000))
              (delete-region (point-min) (point))
              (setq line-count 5000)))))
      (when (and (not notified)
                 (string-match-p "Started .* in" output))
        (setq notified t)
        (java-server--spring-boot-set-status 'running)
        (java-server--notify
         "Spring Boot"
         (format "Application ready%s"
                 (if debug (format " [JPDA :%d]" java-server-spring-boot-debug-port) "")))
        (message "Spring Boot ready%s"
                 (if debug (format " [JPDA :%d]" java-server-spring-boot-debug-port) ""))
        (when (and debug java-server-auto-dape-on-debug)
          (java-server--dape-attach java-server-spring-boot-debug-port))))))

(defun java-server--spring-boot-build-cmd (details)
  "Return the build command string for DETAILS."
  (let ((home (plist-get details :home))
        (build-system (plist-get details :build-system)))
    (pcase build-system
      ('maven (format "cd %s && mvn package -DskipTests"
                      (shell-quote-argument (directory-file-name home))))
      ('gradle (format "cd %s && ./gradlew bootJar"
                       (shell-quote-argument (directory-file-name home))))
      (_ (user-error "Unknown build system for Spring Boot")))))

(defun java-server--spring-boot-java-cmd (jar debug)
  "Return the java command to run JAR.
DEBUG non-nil enables JPDA."
  (if debug
      (format "java -agentlib:jdwp=transport=dt_socket,address=%d,server=y,suspend=n -jar %s"
              java-server-spring-boot-debug-port
              (shell-quote-argument jar))
    (format "java -jar %s" (shell-quote-argument jar))))

(defun java-server--spring-boot-start-app (details debug)
  "Start the Spring Boot application from DETAILS.
DEBUG non-nil enables JPDA."
  (let* ((home (plist-get details :home))
         (name (plist-get details :name))
         (jar (java-server--spring-boot-find-jar home)))
    (unless jar
      (user-error "No JAR found in %s (searched target/ and build/libs/)" home))
    (let* ((cmd (java-server--spring-boot-java-cmd jar debug))
           (buf-name (format "*spring-boot[%s]*" name))
           (proc-name (format "spring-boot[%s]" name))
           (proc (start-process-shell-command proc-name buf-name cmd)))
      (setq java-server--spring-boot-process proc)
      (java-server--spring-boot-set-status 'starting)
      (set-process-filter proc (java-server--spring-boot-startup-filter debug))
      (set-process-sentinel
       proc
       (lambda (_proc event)
         (when (string-match-p
                (rx (or "finished" "exited" "failed" "killed"))
                event)
           (java-server--spring-boot-set-status nil)
           (setq java-server--spring-boot-process nil)))))))

;;;###autoload
(defun java-server-spring-boot-run (debug)
  "Build and run Spring Boot application.
With prefix argument DEBUG, enable JPDA remote debugging.
Automatically detects the JDK version from pom.xml and uses it
for build and run subprocesses without changing the global JAVA_HOME."
  (interactive "P")
  (let* ((details (java-server--detect-project))
         (project-jdk (java-server--resolve-project-jdk))
         (process-environment (if project-jdk
                                  (java-server--process-environment-for-jdk project-jdk)
                                process-environment))
         (build-cmd (java-server--spring-boot-build-cmd details))
         (build-buf "*spring-boot-build*"))
    (when project-jdk
      (message "Using project JDK: %s" project-jdk))
    (message "Building project (%s)..."
             (if (eq (plist-get details :build-system) 'maven)
                 "mvn package -DskipTests"
               "./gradlew bootJar"))
    (set-process-sentinel
     (start-process-shell-command "spring-boot-build" build-buf build-cmd)
     (let ((captured-details details)
           (captured-debug debug)
           (captured-env process-environment))
       (lambda (proc _event)
         (if (= 0 (process-exit-status proc))
             (let ((process-environment captured-env))
               (message "Build succeeded. Starting Spring Boot...")
               (java-server--spring-boot-start-app captured-details captured-debug))
           (message "Build FAILED. See %s for details." build-buf)))))))

;;;###autoload
(defun java-server-spring-boot-stop ()
  "Stop the running Spring Boot application."
  (interactive)
  (if (and java-server--spring-boot-process
           (process-live-p java-server--spring-boot-process))
      (progn
        (kill-process java-server--spring-boot-process)
        (setq java-server--spring-boot-process nil)
        (java-server--spring-boot-set-status nil)
        (message "Spring Boot stopped."))
    (message "No Spring Boot process running.")))

;;; ============================================================
;;; Module 6: dape integration
;;; ============================================================

(defun java-server--dape-attach (jpda-port)
  "Attach dape debugger to JPDA-PORT.
If eglot+JDTLS is available, use JDTLS debug adapter.
Otherwise report that manual setup is needed."
  (unless (featurep 'dape)
    (user-error "dape is not loaded; cannot attach debugger"))
  (if-let* ((server (and (featurep 'eglot)
                         (ignore-errors (eglot-current-server))))
            (adapter-port (ignore-errors
                            (eglot-execute-command
                             server "vscode.java.startDebugSession" nil))))
      (progn
        (message "Attaching dape via JDTLS debug adapter on port %s..." adapter-port)
        (dape `(:request "attach"
                :hostname "localhost"
                :port ,adapter-port)))
    (message "No JDTLS server found. Use M-x dape to attach manually to port %d." jpda-port)))

(defun java-server--register-dape-configs ()
  "Register java-server dape configurations."
  (when (boundp 'dape-configs)
    (add-to-list 'dape-configs
                 `(java-server-tomcat
                   modes (java-mode java-ts-mode)
                   :request "attach"
                   :hostname "localhost"
                   :port ,java-server-tomcat-debug-port))
    (add-to-list 'dape-configs
                 `(java-server-spring-boot
                   modes (java-mode java-ts-mode)
                   :request "attach"
                   :hostname "localhost"
                   :port ,java-server-spring-boot-debug-port))))

(with-eval-after-load 'dape
  (java-server--register-dape-configs))

;;; ============================================================
;;; Module 7: Minor mode
;;; ============================================================

(defvar java-server-mode-map (make-sparse-keymap)
  "Keymap for `java-server-mode'.
No default bindings are set to avoid conflicts with eglot and
other minor modes.  Users can bind keys as needed, e.g.:

  (keymap-set java-server-mode-map \"C-c C-d\" #\\='java-server-tomcat-deploy)")

;;;###autoload
(define-minor-mode java-server-mode
  "Minor mode for Java server development utilities.
Provides key bindings for common operations via `java-server-mode-map'.
Mode-line indicators for Tomcat and Spring Boot are managed automatically
and do not require this mode to be active."
  :lighter " JSrv"
  :keymap java-server-mode-map)

;;; ============================================================
;;; Module 8: Utility commands
;;; ============================================================

;;;###autoload
(defun java-server-mapper-find-xml ()
  "Jump from a Java mapper file to the corresponding XML mapper file.
If the cursor is on a method name, jump to that method's definition
in the XML file.  Uses xref marker stack for navigation back."
  (interactive)
  (let* ((java-file (buffer-file-name))
         (xml-file (and java-file
                        (concat (file-name-sans-extension java-file) ".xml")))
         (method-name (thing-at-point 'symbol t)))
    (if (and xml-file (file-exists-p xml-file))
        (progn
          (xref-push-marker-stack)
          (find-file xml-file)
          (goto-char (point-min))
          (if method-name
              (if (re-search-forward
                   (concat "id=\"\\(" (regexp-quote method-name) "\\)\"")
                   nil t)
                  (message "Jumped to method: %s" method-name)
                (message "Method '%s' not found in XML file." method-name))
            (message "Opened XML file. Put point on Java method and retry to jump by id.")))
      (message "No corresponding XML file found."))))

;;;###autoload
(defun java-server-decompile-class ()
  "Decompile the current .class file using FernFlower."
  (interactive)
  (let ((current-file (buffer-file-name)))
    (unless (and current-file
                 (string-equal (file-name-extension current-file) "class"))
      (user-error "This command can only be run on .class files"))
    (let* ((output-dir (concat (file-name-directory current-file) "decompiled/"))
           (decompiled-file (concat output-dir (file-name-base current-file) ".java"))
           (command (format "fernflower %s %s"
                            (shell-quote-argument current-file)
                            (shell-quote-argument output-dir))))
      (unless (file-directory-p output-dir)
        (make-directory output-dir t))
      (message "Running FernFlower decompiler...")
      (shell-command command)
      (if (file-exists-p decompiled-file)
          (find-file decompiled-file)
        (user-error "Decompiled file not found at %s" decompiled-file)))))

(provide 'java-server)
;;; java-server.el ends here
