# java-server

Single-file Emacs helpers for local Java server work.

`java-server.el` covers the repetitive parts of the workflow:

- detect the current Java project with `project.el`
- pick a project-specific JDK without mutating the global `JAVA_HOME`
- build and deploy WARs to local Tomcat
- build and run Spring Boot applications
- attach `dape` through JDTLS/java-debug
- trigger hot code replace for local debug sessions
- jump between MyBatis mapper interfaces and XML files
- decompile `.class` files with FernFlower

## Requirements

- Emacs 29.1+
- macOS or Linux
- local JDK installation
- Maven and/or Gradle wrapper for the target project
- local Tomcat if using Tomcat deploy commands
- optional:
  - `dape`
  - `eglot`
  - `fernflower`

For Java debug attach, JDTLS must already be running with the `java-debug` plugin loaded.

## Installation

Load `java-server.el` from your Emacs configuration.

```elisp
(use-package java-server
  :load-path "~/repos/java-server"
  :commands
  (java-server-mode
   java-server-tomcat-deploy
   java-server-tomcat-stop
   java-server-spring-boot-run
   java-server-spring-boot-stop
   java-server-select-jdk
   java-server-auto-select-jdk
   java-server-hot-replace
   java-server-mapper-find-xml
   java-server-decompile-class))
```

## Main Commands

- `M-x java-server-select-jdk`
- `M-x java-server-auto-select-jdk`
- `M-x java-server-tomcat-deploy`
- `M-x java-server-tomcat-stop`
- `M-x java-server-spring-boot-run`
- `M-x java-server-spring-boot-stop`
- `M-x java-server-hot-replace`
- `M-x java-server-mapper-find-xml`
- `M-x java-server-decompile-class`

## Debug Attach

When Tomcat or Spring Boot is started in debug mode and `dape` is loaded, `java-server` does not attach directly to the JVM debug port with a raw DAP config. It asks JDTLS to start a Java debug adapter first, then attaches `dape` to that adapter.

That distinction matters:

- the top-level DAP `host` and `port` point at the Java debug adapter
- the Java-specific `:hostName` and `:port` point at the target JVM's JPDA socket

If there is no active project JDTLS session, auto-attach is skipped and `java-server` tells you which project root is missing.

## Hot Code Replace

`java-server` tracks saved Java top-level classes while a `dape` Java debug session is active. When HCR runs, it prefers a direct JVM redefine path for local processes started by `java-server` itself.

Current HCR flow:

1. Resolve the active project and saved top-level class names.
2. Find the local JVM PID for the Tomcat or Spring Boot process started by `java-server`.
3. Compile or reuse a tiny Attach API helper under `~/.emacs.d/java-server-hcr/`, cached per JDK major version.
4. Use the Attach API to load an agent into the target JVM and call `Instrumentation.redefineClasses(...)` for the changed class files.
5. For local Tomcat exploded deployments, sync the same class family into `webapps/<project>/WEB-INF/classes/` as a fallback for classes that were not yet loaded.

If direct Attach API HCR is not available, `java-server` falls back to java-debug's `redefineClasses` request.

### What This Solves

- avoids java-debug HCR timeouts caused by JDWP bookkeeping on running services
- works without restarting local Tomcat or Spring Boot when the change is a valid class redefinition
- keeps local Tomcat exploded classes in sync with the latest compiled output

### What It Does Not Solve

- field layout changes, method signature changes, superclass/interface changes, and other structural edits still require a restart
- if the target class was not yet loaded, the redefine step reports that explicitly; the copied class file only affects future class loading
- class lookup currently covers Maven `target/classes` and Gradle `build/classes/java/main` style outputs

## Notes

- Tomcat deploy assumes a Maven WAR build.
- Spring Boot run supports Maven and Gradle builds.
- Project-specific JDK resolution currently reads Maven `pom.xml`.
- For variable inspection in `dape`, `eldoc-mode`, watch expressions, and `dape-evaluate-expression` are usually more useful than only watching the raw locals tree.
