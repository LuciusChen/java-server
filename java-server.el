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
;;
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)

(declare-function eglot-current-server "eglot")
(declare-function eglot-execute-command "eglot")
(declare-function eglot--managed-buffers "eglot")
(declare-function eglot--project "eglot")
(declare-function dape "dape")
(declare-function dape-continue "dape")
(declare-function dape-handle-event "dape")
(declare-function dape-pause "dape")
(declare-function dape-request "dape")
(declare-function dape--state "dape")
(declare-function jsonrpc-running-p "jsonrpc")
(declare-function notifications-notify "notifications")
(defvar dape-request-timeout)
(defvar eglot--servers-by-project)

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

(defcustom java-server-hot-code-replace-mode 'auto
  "Hot code replace mode for Java debug sessions.
`auto'   — replace classes after java-debug reports a completed build.
`manual' — use `java-server-hot-replace' to trigger manually.
`never'  — disable hot code replace."
  :type '(choice (const auto)
                 (const manual)
                 (const never))
  :group 'java-server)

(defcustom java-server-jdwp-request-timeout 30000
  "JDWP request timeout in milliseconds for java-debug operations.
This is synced to java-debug via `vscode.java.updateDebugSettings'."
  :type 'natnum
  :group 'java-server)

(defcustom java-server-tomcat-sync-classes-on-hcr t
  "Whether to sync saved class files into Tomcat's exploded webapp after HCR.
This is a fallback for local Tomcat workflows where the deployed
`WEB-INF/classes' tree lags behind the project's compiled classes output."
  :type 'boolean
  :group 'java-server)

(defcustom java-server-direct-attach-hcr t
  "Whether to prefer direct JVM class redefinition for local debug sessions.
When non-nil, java-server uses the Attach API to redefine saved classes
inside Tomcat or Spring Boot processes launched by java-server itself.
This bypasses java-debug's unreliable HCR bookkeeping."
  :type 'boolean
  :group 'java-server)

(defcustom java-server-direct-attach-hcr-helper-dir
  (expand-file-name "java-server-hcr/" user-emacs-directory)
  "Base directory where java-server stores its Attach API helper caches.
java-server keeps one helper cache per JDK major version under this directory."
  :type 'directory
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

(defvar java-server--tomcat-project-details nil
  "Project details plist for the Tomcat instance launched by java-server.")

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

(defun java-server--tomcat-startup-filter (debug details)
  "Return a process filter that detects Tomcat startup.
DEBUG non-nil means JPDA mode is active.
DETAILS is the project plist used for debugger attach."
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
          (java-server--dape-attach java-server-tomcat-debug-port details))))))

(defun java-server--tomcat-do-start (proc-name buf-name start-cmd debug details)
  "Start Tomcat process PROC-NAME in BUF-NAME using START-CMD.
DEBUG non-nil means JPDA mode.
DETAILS is the project plist used for debugger attach."
  (message "Starting Tomcat%s..." (if debug " with JPDA" ""))
  (java-server--tomcat-set-status 'starting)
  (setq java-server--tomcat-project-details details)
  (let ((proc (start-process-shell-command proc-name buf-name start-cmd)))
    (set-process-filter proc (java-server--tomcat-startup-filter debug details))
    (set-process-sentinel
     proc
     (lambda (_proc event)
       (when (string-match-p
              (rx (or "finished" "exited" "failed" "killed"))
              event)
         (java-server--tomcat-set-status nil)
         (setq java-server--tomcat-project-details nil))))))

(defun java-server--tomcat-wait-then-start (proc-name buf-name start-cmd debug remaining env details)
  "Poll until Tomcat port closes, then start.
Retry every second up to REMAINING times.
ENV is the `process-environment' to use for the subprocess.
DETAILS is the project plist used for debugger attach."
  (cond
   ((not (java-server--port-open-p "localhost" java-server-tomcat-port))
    (let ((process-environment env))
      (java-server--tomcat-do-start proc-name buf-name start-cmd debug details)))
   ((> remaining 0)
    (run-with-timer 1 nil #'java-server--tomcat-wait-then-start
                    proc-name buf-name start-cmd debug (1- remaining) env details))
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
             proc-name buf-name startup-command debug 30 process-environment details))
        (java-server--tomcat-do-start proc-name buf-name startup-command debug details)))))

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
      (setq java-server--tomcat-project-details nil)
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

(defvar java-server--spring-boot-project-details nil
  "Project details plist for the Spring Boot instance launched by java-server.")

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

(defun java-server--spring-boot-startup-filter (debug details)
  "Return a process filter that detects Spring Boot startup.
DEBUG non-nil means JPDA is active.
DETAILS is the project plist used for debugger attach."
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
          (java-server--dape-attach java-server-spring-boot-debug-port details))))))

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
      (setq java-server--spring-boot-project-details details)
      (java-server--spring-boot-set-status 'starting)
      (set-process-filter proc (java-server--spring-boot-startup-filter debug details))
      (set-process-sentinel
       proc
       (lambda (_proc event)
         (when (string-match-p
                (rx (or "finished" "exited" "failed" "killed"))
                event)
           (java-server--spring-boot-set-status nil)
           (setq java-server--spring-boot-process nil
                 java-server--spring-boot-project-details nil)))))))

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
        (setq java-server--spring-boot-project-details nil)
        (java-server--spring-boot-set-status nil)
        (message "Spring Boot stopped."))
    (message "No Spring Boot process running.")))

;;; ============================================================
;;; Module 6: dape integration
;;; ============================================================

(defun java-server--dape-attach (jpda-port &optional details)
  "Attach dape debugger to JPDA-PORT.
If eglot+JDTLS is available, use JDTLS debug adapter.
DETAILS is the project plist used to find the matching server."
  (unless (featurep 'dape)
    (user-error "dape is not loaded; cannot attach debugger"))
  (condition-case err
      (let* ((config (java-server--dape-resolve-attach-config
                      `(:port ,jpda-port) details))
             (adapter-port (plist-get config 'port)))
        (message "Attaching dape via JDTLS debug adapter on port %s..." adapter-port)
        (dape config))
    (error
     (message "Debugger auto-attach skipped: %s" (error-message-string err)))))

(defun java-server--project-path-match-p (path project-home)
  "Return non-nil if PATH belongs to PROJECT-HOME."
  (let ((path (file-name-as-directory (file-truename path)))
        (project-home (file-name-as-directory (file-truename project-home))))
    (or (string= path project-home)
        (file-in-directory-p path project-home))))

(defun java-server--project-eglot-buffer (project-home)
  "Return a buffer under PROJECT-HOME with an active JDTLS server."
  (seq-find
   (lambda (buffer)
     (when-let* ((file (buffer-local-value 'buffer-file-name buffer)))
       (with-current-buffer buffer
         (and (java-server--project-path-match-p file project-home)
              (ignore-errors (eglot-current-server))))))
   (buffer-list)))

(defun java-server--project-eglot-server-from-registry (project-home)
  "Return a running JDTLS server for PROJECT-HOME from Eglot's registry."
  (when (and (featurep 'eglot)
             (boundp 'eglot--servers-by-project))
    (let (match)
      (maphash
       (lambda (project servers)
         (when-let* ((root (ignore-errors (project-root project)))
                     ((java-server--project-path-match-p project-home root))
                     (server (seq-find #'jsonrpc-running-p servers)))
           (setq match (or match server))))
       eglot--servers-by-project)
      match)))

(defun java-server--project-eglot-server (details)
  "Return the JDTLS server associated with DETAILS, or nil."
  (when (featurep 'eglot)
    (when-let* ((home (plist-get details :home)))
      (or (when-let* ((buffer (java-server--project-eglot-buffer home)))
            (with-current-buffer buffer
              (eglot-current-server)))
          (java-server--project-eglot-server-from-registry home)))))

(defun java-server--hot-code-replace-setting ()
  "Return the java-debug hot code replace setting string."
  (pcase java-server-hot-code-replace-mode
    ('auto "auto")
    ('manual "manual")
    (_ "never")))

(defun java-server--debug-settings-json ()
  "Return the java-debug settings JSON string."
  (format
   "{\"hotCodeReplace\":\"%s\",\"jdwpRequestTimeout\":%d,\"logLevel\":\"INFO\"}"
   (java-server--hot-code-replace-setting)
   java-server-jdwp-request-timeout))

(defun java-server--sync-debug-settings (server)
  "Sync java-debug settings to SERVER.
Ignore command failures because some JDTLS builds reject this command
even though the debug session itself can still be started."
  (condition-case err
      (eglot-execute-command
       server "vscode.java.updateDebugSettings"
       (vector (java-server--debug-settings-json)))
    (error
     (message "java-debug settings sync skipped: %s"
              (error-message-string err))
     nil)))

(defun java-server--start-debug-session (details)
  "Start a JDTLS-backed java debug session for DETAILS.
Return the adapter port."
  (if-let* ((server (java-server--project-eglot-server details)))
      (progn
        (java-server--sync-debug-settings server)
        (condition-case err
            (eglot-execute-command server "vscode.java.startDebugSession" nil)
          (error
           (user-error "java-debug startDebugSession failed: %s"
                       (error-message-string err)))))
    (user-error "No active JDTLS server found for %s" (plist-get details :home))))

(defvar java-server--active-debug-project-details nil
  "Project details plist for the current java-server-managed dape session.")

(defun java-server--dape-resolve-attach-config (config &optional details)
  "Resolve dape CONFIG for a Java JPDA attach session.
DETAILS is the project plist used to find the matching JDTLS server."
  (let* ((details (or details (java-server--detect-project)))
         (project-home (plist-get details :home))
         (project-name (plist-get details :name))
         (jpda-port (or (plist-get config :port)
                        (plist-get config 'jpda-port)
                        (user-error "Missing JPDA port")))
         (adapter-port (java-server--start-debug-session details))
         (config (copy-tree config)))
    (setq config (plist-put config 'host "localhost"))
    (setq config (plist-put config 'port adapter-port))
    (setq config (plist-put config :type "java"))
    (setq config (plist-put config :request "attach"))
    (setq config (plist-put config :hostName
                            (or (plist-get config :hostName) "localhost")))
    (setq config (plist-put config :port jpda-port))
    (setq config (plist-put config :projectName
                            (or (plist-get config :projectName) project-name)))
    (setq java-server--active-debug-project-details details)
    (setq config (plist-put config 'project-details details))
    (setq config (plist-put config :sourcePaths
                            (or (plist-get config :sourcePaths)
                                (vector project-home))))
    (plist-put config :timeout (or (plist-get config :timeout) 30000))))

(defun java-server--ensure-dape-attach-prerequisites (config)
  "Validate CONFIG can attach through JDTLS."
  (let ((details (or (plist-get config 'project-details)
                     (java-server--detect-project))))
    (unless (java-server--project-eglot-server details)
      (user-error "No active JDTLS server found for %s" (plist-get details :home)))))

(defun java-server--active-dape-connection ()
  "Return the current live dape connection, or nil."
  (when (featurep 'dape)
    (when-let* ((conn (and (boundp 'dape--connection)
                           (symbol-value 'dape--connection))))
      (and (ignore-errors (jsonrpc-running-p conn)) conn))))

(defun java-server--dape-stopped-p (conn)
  "Return non-nil if CONN is currently stopped."
  (eq (ignore-errors (dape--state conn)) 'stopped))

(defvar java-server--pending-hcr-target-classes nil
  "Top-level Java classes saved since the last hot code replace request.")

(defvar java-server--pending-hcr-project-details nil
  "Project details plist captured from the last saved Java buffer for HCR.")

(defvar java-server--hcr-in-progress nil
  "Non-nil while a hot code replace request is in flight.")

(defvar java-server--pending-hot-replace nil
  "Non-nil when a hot code replace should run on the next stop event.")

(defvar java-server--hcr-auto-resume nil
  "Non-nil when java-server should resume after an auto-paused HCR.")

(defun java-server--same-project-home-p (left right)
  "Return non-nil when LEFT and RIGHT denote the same project root."
  (and left
       right
       (string=
        (file-name-as-directory (file-truename left))
        (file-name-as-directory (file-truename right)))))

(defun java-server--classes-output-root (details &optional existing-only)
  "Return the compiled classes root for project DETAILS.
When EXISTING-ONLY is non-nil, return nil unless the directory exists."
  (when-let* ((project-home (plist-get details :home)))
    (let* ((candidates
            (pcase (plist-get details :build-system)
              ('gradle '("build/classes/java/main/"
                         "build/classes/kotlin/main/"
                         "build/classes/main/"
                         "target/classes/"))
              (_ '("target/classes/"
                   "build/classes/java/main/"
                   "build/classes/kotlin/main/"
                   "build/classes/main/"))))
           (paths (mapcar (lambda (relative)
                            (expand-file-name relative project-home))
                          candidates))
           (existing (seq-find #'file-directory-p paths)))
      (if existing-only
          existing
        (or existing (car paths))))))

(defun java-server--buffer-java-primary-class ()
  "Return the current buffer's top-level Java class name, or nil."
  (when-let* ((file buffer-file-name)
              ((string-suffix-p ".java" file))
              (base (file-name-base file))
              ((not (member base '("package-info" "module-info")))))
    (let ((package
           (save-excursion
             (goto-char (point-min))
             (when (re-search-forward
                    "^[[:space:]]*package[[:space:]]+\\([[:word:].]+\\)[[:space:]]*;"
                    nil t)
               (match-string-no-properties 1)))))
      (if (and package (not (string= package "")))
          (concat package "." base)
        base))))

(defun java-server--track-saved-java-class ()
  "Remember the current Java buffer's top-level class for the next HCR."
  (when (and (java-server--active-dape-connection)
             java-server--active-debug-project-details
             (derived-mode-p 'java-mode 'java-ts-mode))
    (when-let* ((details
                 (ignore-errors
                   (java-server--detect-project (file-name-directory buffer-file-name))))
                ((java-server--same-project-home-p
                  (plist-get details :home)
                  (plist-get java-server--active-debug-project-details :home)))
                (class-name (java-server--buffer-java-primary-class)))
      (setq java-server--pending-hcr-project-details
            java-server--active-debug-project-details)
      (cl-pushnew class-name java-server--pending-hcr-target-classes
                  :test #'equal))))

(defun java-server--hcr-target-hit-p (target-class changed-classes)
  "Return non-nil when TARGET-CLASS is present in CHANGED-CLASSES.
Inner classes are treated as a hit for their top-level class."
  (let ((inner-prefix (concat target-class "$")))
    (seq-some (lambda (class-name)
                (or (equal class-name target-class)
                    (string-prefix-p inner-prefix class-name)))
              changed-classes)))

(defun java-server--hcr-result-message (changed-classes)
  "Format a user-facing HCR result message for CHANGED-CLASSES."
  (let* ((reported (length changed-classes))
         (targets java-server--pending-hcr-target-classes)
         (matched (seq-filter
                   (lambda (target)
                     (java-server--hcr-target-hit-p target changed-classes))
                   targets)))
    (cond
     ((zerop reported)
      "HCR completed; java-debug reported no pending class-file changes.")
     ((null targets)
      (format "HCR completed; java-debug reported %d built class changes."
              reported))
     ((null matched)
      (format "HCR completed; java-debug reported %d built class changes, but not the last saved class (%s)."
              reported
              (mapconcat #'identity targets ", ")))
     (t
      (format "HCR completed; java-debug reported %d built class changes, including %s."
              reported
              (mapconcat #'identity matched ", "))))))

(defun java-server--tomcat-exploded-classes-dir (details)
  "Return Tomcat exploded `WEB-INF/classes' dir for project DETAILS, or nil."
  (when-let* ((tomcat-home (and java-server-tomcat-sync-classes-on-hcr
                                (java-server--detect-tomcat-home)))
              (project-name (plist-get details :name))
              (classes-dir (expand-file-name
                            (format "webapps/%s/WEB-INF/classes/" project-name)
                            tomcat-home))
              ((file-directory-p classes-dir)))
    classes-dir))

(defun java-server--class-family-files (details class-name)
  "Return compiled class files for CLASS-NAME for project DETAILS."
  (let* ((parts (split-string class-name "\\."))
         (base-name (car (last parts)))
         (package-dir (mapconcat #'identity (butlast parts) "/"))
         (classes-root (java-server--classes-output-root details 'existing-only))
         (classes-dir (and classes-root
                           (expand-file-name package-dir classes-root))))
    (when (file-directory-p classes-dir)
      (directory-files
       classes-dir t
       (concat "^" (regexp-quote base-name) "\\(?:\\$.*\\)?\\.class$")
       t))))

(defun java-server--sync-class-family-to-tomcat (details class-name)
  "Copy CLASS-NAME compiled class files into the local Tomcat exploded webapp."
  (when-let* ((classes-dir (java-server--tomcat-exploded-classes-dir details))
              (source-files (java-server--class-family-files details class-name)))
    (let* ((parts (split-string class-name "\\."))
           (package-dir (mapconcat #'identity (butlast parts) "/"))
           (dest-dir (expand-file-name package-dir classes-dir)))
      (make-directory dest-dir t)
      (dolist (file source-files)
        (copy-file file (expand-file-name (file-name-nondirectory file) dest-dir) t))
      (length source-files))))

(defun java-server--sync-hcr-target-classes-to-tomcat (details targets)
  "Sync TARGETS from PROJECT DETAILS into the local Tomcat exploded webapp."
  (when (and details targets)
    (apply #'+
           (mapcar (lambda (class-name)
                     (or (java-server--sync-class-family-to-tomcat details class-name) 0))
                   targets))))

(defconst java-server--direct-hcr-agent-source
  (mapconcat
   #'identity
   '("package inspect;"
     ""
     "import java.io.PrintWriter;"
     "import java.io.StringWriter;"
     "import java.lang.instrument.ClassDefinition;"
     "import java.lang.instrument.Instrumentation;"
     "import java.nio.charset.StandardCharsets;"
     "import java.nio.file.Files;"
     "import java.nio.file.Paths;"
     ""
     "public final class DirectRedefineAgent {"
     "    private DirectRedefineAgent() {}"
     ""
     "    public static void agentmain(String agentArgs, Instrumentation inst) throws Exception {"
     "        String statusFile = null;"
     "        try {"
     "            String className = null;"
     "            String classFile = null;"
     "            for (String piece : agentArgs.split(\"[;\\\\n]\")) {"
     "                int idx = piece.indexOf('=');"
     "                if (idx <= 0) continue;"
     "                String key = piece.substring(0, idx);"
     "                String value = piece.substring(idx + 1);"
     "                if (\"class\".equals(key)) className = value;"
     "                else if (\"file\".equals(key)) classFile = value;"
     "                else if (\"status\".equals(key)) statusFile = value;"
     "            }"
     "            if (className == null || classFile == null || statusFile == null) {"
     "                throw new IllegalArgumentException(\"Missing class/file/status\");"
     "            }"
     "            Class<?> target = null;"
     "            for (Class<?> candidate : inst.getAllLoadedClasses()) {"
     "                if (candidate.getName().equals(className)) {"
     "                    target = candidate;"
     "                    break;"
     "                }"
     "            }"
     "            if (target == null) {"
     "                write(statusFile, \"NOT_LOADED\\n\");"
     "                return;"
     "            }"
     "            byte[] bytes = Files.readAllBytes(Paths.get(classFile));"
     "            inst.redefineClasses(new ClassDefinition(target, bytes));"
     "            write(statusFile, \"OK\\n\");"
     "        } catch (Throwable t) {"
     "            if (statusFile == null) throw t;"
     "            StringWriter sw = new StringWriter();"
     "            t.printStackTrace(new PrintWriter(sw));"
     "            write(statusFile, \"ERROR\\n\" + sw.toString());"
     "        }"
     "    }"
     ""
     "    private static void write(String path, String content) throws Exception {"
     "        Files.write(Paths.get(path), content.getBytes(StandardCharsets.UTF_8));"
     "    }"
     "}")
   "\n"))

(defconst java-server--direct-hcr-loader-source
  (mapconcat
   #'identity
   '("package inspect;"
     ""
     "import com.sun.tools.attach.VirtualMachine;"
     ""
     "public final class LoadAgent {"
     "    private LoadAgent() {}"
     ""
     "    public static void main(String[] args) throws Exception {"
     "        if (args.length != 3) {"
     "            throw new IllegalArgumentException(\"usage: <pid> <agent-jar> <agent-args>\");"
     "        }"
     "        VirtualMachine vm = VirtualMachine.attach(args[0]);"
     "        try {"
     "            vm.loadAgent(args[1], args[2]);"
     "        } finally {"
     "            vm.detach();"
     "        }"
     "    }"
     "}")
   "\n"))

(defconst java-server--direct-hcr-manifest
  (mapconcat
   #'identity
   '("Manifest-Version: 1.0"
     "Agent-Class: inspect.DirectRedefineAgent"
     "Can-Redefine-Classes: true"
     "")
   "\n"))

(defun java-server--write-file-if-changed (file content)
  "Write CONTENT to FILE only when the file contents differ."
  (make-directory (file-name-directory file) t)
  (unless (and (file-exists-p file)
               (string= (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string))
                        content))
    (with-temp-file file
      (insert content))))

(defun java-server--run-process-file-checked (program &rest args)
  "Run PROGRAM with ARGS and return stdout, or signal an error."
  (with-temp-buffer
    (let ((status (apply #'process-file program nil t nil args))
          (output (buffer-string)))
      (if (zerop status)
          output
        (error "%s failed: %s"
               (file-name-nondirectory program)
               (string-trim output))))))

(defun java-server--jdk-major-version-string (version)
  "Return the JDK major version parsed from VERSION."
  (cond
   ((string-match "\\`1\\.\\([0-9]+\\)\\(?:[._].*\\)?\\'" version)
    (match-string 1 version))
   ((string-match "\\`\\([0-9]+\\)\\(?:[._].*\\)?\\'" version)
    (match-string 1 version))
   (t nil)))

(defun java-server--direct-hcr-helper-cache-dir (jdk-home)
  "Return the helper cache dir for JDK-HOME."
  (let* ((base-dir (file-name-as-directory java-server-direct-attach-hcr-helper-dir))
         (release-file (expand-file-name "release" jdk-home))
         (major-version
          (when (file-exists-p release-file)
            (with-temp-buffer
              (insert-file-contents release-file)
              (when (re-search-forward "^JAVA_VERSION=\"\\([^\"]+\\)\"" nil t)
                (java-server--jdk-major-version-string
                 (match-string-no-properties 1))))))
         (cache-name (format "jdk-%s" (or major-version "unknown"))))
    (expand-file-name (file-name-as-directory cache-name) base-dir)))

(defun java-server--direct-hcr-jdk-home (&optional details)
  "Return a JDK home suitable for direct Attach API HCR."
  (or (ignore-errors (java-server--resolve-project-jdk))
      (getenv "JAVA_HOME")
      (when (eq system-type 'darwin)
        (let ((home (string-trim
                     (shell-command-to-string "/usr/libexec/java_home 2>/dev/null"))))
          (unless (string-empty-p home) home)))
      (and details
           (plist-get details :home)
           (let* ((default-directory (plist-get details :home))
                  (java-bin (executable-find "java")))
             (when java-bin
               (directory-file-name
                (expand-file-name ".." (file-name-directory java-bin))))))))

(defun java-server--direct-hcr-helper-jar (jdk-home)
  "Ensure the direct Attach API helper exists for JDK-HOME and return its JAR."
  (let* ((helper-dir (java-server--direct-hcr-helper-cache-dir jdk-home))
         (src-dir (expand-file-name "inspect/" helper-dir))
         (classes-dir (expand-file-name "classes/" helper-dir))
         (agent-java (expand-file-name "DirectRedefineAgent.java" src-dir))
         (loader-java (expand-file-name "LoadAgent.java" src-dir))
         (manifest (expand-file-name "MANIFEST.MF" helper-dir))
         (jar-file (expand-file-name "direct-hcr-agent.jar" helper-dir))
         (javac (expand-file-name "bin/javac" jdk-home))
         (jar (expand-file-name "bin/jar" jdk-home))
         (tools-jar (expand-file-name "lib/tools.jar" jdk-home)))
    (unless (file-executable-p javac)
      (error "No javac found in %s" jdk-home))
    (unless (file-executable-p jar)
      (error "No jar tool found in %s" jdk-home))
    (java-server--write-file-if-changed agent-java java-server--direct-hcr-agent-source)
    (java-server--write-file-if-changed loader-java java-server--direct-hcr-loader-source)
    (java-server--write-file-if-changed manifest java-server--direct-hcr-manifest)
    (when (or (not (file-exists-p jar-file))
              (file-newer-than-file-p agent-java jar-file)
              (file-newer-than-file-p loader-java jar-file)
              (file-newer-than-file-p manifest jar-file))
      (when (file-directory-p classes-dir)
        (delete-directory classes-dir t))
      (make-directory classes-dir t)
      (if (file-exists-p tools-jar)
          (java-server--run-process-file-checked
           javac "-cp" tools-jar "-d" classes-dir agent-java loader-java)
        (java-server--run-process-file-checked
         javac "-d" classes-dir agent-java loader-java))
      (when (file-exists-p jar-file)
        (delete-file jar-file))
      (java-server--run-process-file-checked
       jar "cfm" jar-file manifest "-C" classes-dir "."))
    jar-file))

(defun java-server--project-hcr-pid (details)
  "Return the local JVM PID for direct HCR for project DETAILS, or nil."
  (let ((home (plist-get details :home)))
    (cond
     ((and home
           java-server--spring-boot-project-details
           (equal home (plist-get java-server--spring-boot-project-details :home))
           java-server--spring-boot-process
           (process-live-p java-server--spring-boot-process))
      (number-to-string (process-id java-server--spring-boot-process)))
     ((and home
           java-server--tomcat-project-details
           (equal home (plist-get java-server--tomcat-project-details :home)))
      (java-server--tomcat-get-pid))
     ((and home
           (java-server--tomcat-exploded-classes-dir details)
           (java-server--port-open-p "localhost" java-server-tomcat-debug-port))
      (java-server--tomcat-get-pid)))))

(defun java-server--class-file-binary-name (details class-file)
  "Return the JVM binary name for CLASS-FILE for project DETAILS."
  (let* ((classes-dir (file-name-as-directory
                       (or (java-server--classes-output-root details)
                           (error "Unable to resolve compiled classes root"))))
         (relative (file-relative-name class-file classes-dir)))
    (string-replace
     "/"
     "."
     (string-remove-suffix ".class" relative))))

(defun java-server--direct-redefine-class-file (details pid class-file)
  "Directly redefine CLASS-FILE in PID for project DETAILS via the Attach API."
  (let* ((jdk-home (or (java-server--direct-hcr-jdk-home details)
                       (error "Unable to locate a JDK for direct HCR")))
         (java (expand-file-name "bin/java" jdk-home))
         (jar-file (java-server--direct-hcr-helper-jar jdk-home))
         (tools-jar (expand-file-name "lib/tools.jar" jdk-home))
         (class-name (java-server--class-file-binary-name details class-file))
         (helper-dir (java-server--direct-hcr-helper-cache-dir jdk-home))
         (status-file (make-temp-file (expand-file-name "status-" helper-dir)))
         (classpath (if (file-exists-p tools-jar)
                        (mapconcat #'identity (list tools-jar jar-file) path-separator)
                      jar-file))
         (agent-args (format "class=%s;file=%s;status=%s"
                             class-name class-file status-file)))
    (unless (file-executable-p java)
      (error "No java launcher found in %s" jdk-home))
    (unwind-protect
        (progn
          (delete-file status-file)
          (java-server--run-process-file-checked
           java "-cp" classpath "inspect.LoadAgent" pid jar-file agent-args)
          (unless (file-exists-p status-file)
            (error "Direct HCR helper produced no status file"))
          (with-temp-buffer
            (insert-file-contents status-file)
            (cond
             ((string-prefix-p "OK" (buffer-string)) 'ok)
             ((string-prefix-p "NOT_LOADED" (buffer-string)) 'not-loaded)
             (t (error "Direct HCR failed: %s" (string-trim (buffer-string)))))))
      (when (file-exists-p status-file)
        (delete-file status-file)))))

(defun java-server--direct-hot-replace-available-p (details targets)
  "Return non-nil when DETAILS and TARGETS can use direct Attach API HCR."
  (and java-server-direct-attach-hcr
       details
       targets
       (java-server--project-hcr-pid details)))

(defun java-server--direct-hot-replace (details targets)
  "Directly redefine TARGETS for project DETAILS via the Attach API."
  (let* ((pid (or (java-server--project-hcr-pid details)
                  (error "No local JVM PID available for direct HCR")))
         (files (delete-dups
                 (apply #'append
                        (mapcar (lambda (target)
                                  (java-server--class-family-files details target))
                                targets))))
         (applied 0)
         (not-loaded 0))
    (dolist (class-file files)
      (pcase (java-server--direct-redefine-class-file details pid class-file)
        ('ok (cl-incf applied))
        ('not-loaded (cl-incf not-loaded))))
    `(:applied ,applied
      :not-loaded ,not-loaded
      :synced ,(or (java-server--sync-hcr-target-classes-to-tomcat details targets) 0))))

(defun java-server--dape-pause-all (conn)
  "Pause all threads in CONN."
  (dape-request
   ;; java-debug interprets threadId 0 as a whole-VM pause.
   conn :pause '(:threadId 0)
   (lambda (_body error)
     (when error
       (message "HCR queued, but pause failed: %s" error)))))

(defun java-server--dape-continue-all (conn)
  "Resume all threads in CONN."
  (dape-request
   ;; java-debug interprets threadId 0 as a whole-VM resume.
   conn :continue '(:threadId 0)
   (lambda (body error)
     (if error
         (message "HCR applied; auto-resume failed: %s" error)
       ;; Dape expects a synthetic continued event here, same as `dape-continue'.
       (dape-handle-event
        conn 'continued
        `(:threadId 0
          :allThreadsContinued
          ,(if (plist-member body :allThreadsContinued)
               (eq (plist-get body :allThreadsContinued) t)
             t)))))))

(defun java-server--queue-hot-replace (conn)
  "Queue HCR for CONN and pause execution if needed."
  (if java-server--pending-hot-replace
      (message "HCR already queued; waiting for debugger to stop.")
    (setq java-server--pending-hot-replace t
          java-server--hcr-auto-resume t)
    (message "HCR queued; pausing all debug threads...")
    (java-server--dape-pause-all conn)))

(defun java-server--request-hot-replace (conn &optional interactive)
  "Send a hot code replace request on CONN.
When INTERACTIVE is non-nil, keep user-facing messages explicit."
  (let ((targets java-server--pending-hcr-target-classes)
        (details java-server--pending-hcr-project-details))
    (cond
     (java-server--hcr-in-progress
      (if interactive
          (user-error "Hot code replace already in progress")
        (message "HCR already in progress.")))
     ((java-server--direct-hot-replace-available-p details targets)
      (setq java-server--pending-hot-replace nil
            java-server--hcr-in-progress t)
      (message "Running direct HCR...")
      (unwind-protect
          (let* ((result (java-server--direct-hot-replace details targets))
                 (applied (plist-get result :applied))
                 (not-loaded (plist-get result :not-loaded))
                 (synced (plist-get result :synced)))
            (message
             "HCR applied %d loaded classes via Attach API%s%s"
             applied
             (if (> not-loaded 0)
                 (format "; %d classes were not yet loaded" not-loaded)
               "")
             (if (> synced 0)
                 (format ". Synced %d class files to Tomcat webapp." synced)
               ".")))
        (setq java-server--hcr-in-progress nil
              java-server--pending-hcr-target-classes nil
              java-server--pending-hcr-project-details nil
              java-server--hcr-auto-resume nil)))
     ((not (java-server--dape-stopped-p conn))
      (java-server--queue-hot-replace conn))
     (t
      (setq java-server--pending-hot-replace nil)
      (setq java-server--hcr-in-progress t)
      (message "Running HCR...")
      (let ((dape-request-timeout 30))
        (dape-request
         conn :redefineClasses nil
         (lambda (body error)
           (let* ((changed-classes (or (plist-get body :changedClasses) []))
                  (targets java-server--pending-hcr-target-classes)
                  (details java-server--pending-hcr-project-details)
                  (synced-count
                   (and (not error)
                        (not (plist-get body :errorMessage))
                        (java-server--sync-hcr-target-classes-to-tomcat details targets))))
             (setq java-server--hcr-in-progress nil)
             (cond
              (error
               (message "HCR request failed: %s" error))
              ((plist-get body :errorMessage)
               (message "HCR failed: %s" (plist-get body :errorMessage)))
              (t
               (message "%s%s"
                        (java-server--hcr-result-message changed-classes)
                        (if (and synced-count (> synced-count 0))
                            (format " Synced %d class files to Tomcat webapp."
                                    synced-count)
                          ""))))
             (setq java-server--pending-hcr-target-classes nil
                   java-server--pending-hcr-project-details nil))
           (when (and java-server--hcr-auto-resume
                      (java-server--dape-stopped-p conn))
             (setq java-server--hcr-auto-resume nil)
             (java-server--dape-continue-all conn))
           (unless (java-server--dape-stopped-p conn)
             (setq java-server--hcr-auto-resume nil)))))))))

;;;###autoload
(defun java-server-hot-replace ()
  "Trigger hot code replace on the active debug session.
Requires dape connected via JPDA to a java-debug adapter."
  (interactive)
  (if-let* ((conn (java-server--active-dape-connection)))
      (java-server--request-hot-replace conn 'interactive)
    (user-error "No active Java debug session")))

(defun java-server--clear-hcr-state ()
  "Reset all HCR-related state variables."
  (setq java-server--hcr-in-progress nil
        java-server--pending-hot-replace nil
        java-server--active-debug-project-details nil
        java-server--pending-hcr-project-details nil
        java-server--pending-hcr-target-classes nil
        java-server--hcr-auto-resume nil))

(defun java-server--register-dape-configs ()
  "Register java-server dape configurations."
  (when (boundp 'dape-configs)
    (add-to-list 'dape-configs
                 `(java-server-tomcat
                   modes (java-mode java-ts-mode)
                   ensure java-server--ensure-dape-attach-prerequisites
                   fn java-server--dape-resolve-attach-config
                   jpda-port ,java-server-tomcat-debug-port))
    (add-to-list 'dape-configs
                 `(java-server-spring-boot
                   modes (java-mode java-ts-mode)
                   ensure java-server--ensure-dape-attach-prerequisites
                   fn java-server--dape-resolve-attach-config
                   jpda-port ,java-server-spring-boot-debug-port))))

(with-eval-after-load 'dape
  (java-server--register-dape-configs)
  (add-hook 'after-save-hook #'java-server--track-saved-java-class)
  (cl-defmethod dape-handle-event :after (conn (_event (eql stopped)) _body)
    "Run pending HCR after the debugger stops."
    (when (and java-server--pending-hot-replace
               (not java-server--hcr-in-progress))
      (java-server--request-hot-replace conn)))
  (cl-defmethod dape-handle-event :after (_conn (_event (eql terminated)) _body)
    "Clear java-server HCR state when the debug session terminates."
    (java-server--clear-hcr-state))
  (cl-defmethod dape-handle-event :after (_conn (_event (eql exited)) _body)
    "Clear java-server HCR state when the debuggee exits."
    (java-server--clear-hcr-state))
  (cl-defmethod dape-handle-event (conn (_event (eql hotcodereplace)) body)
    "Handle hot code replace events from java-debug adapter."
    (let ((change-type (plist-get body :changeType))
          (message-text (plist-get body :message)))
      (pcase change-type
        ("ERROR"         (message "HCR failed: %s" (or message-text "unknown error")))
        ("WARNING"       (message "HCR warning: %s" (or message-text "")))
        ("BUILD_COMPLETE"
         (if (eq java-server-hot-code-replace-mode 'auto)
             (java-server--request-hot-replace conn)
           (message "HCR: class files updated.")))
        (_ nil)))))

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

(provide 'java-server)
;;; java-server.el ends here
