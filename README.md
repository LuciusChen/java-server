# java-server

Emacs utilities for Java server development.

`java-server.el` focuses on the workflows that are awkward to repeat by hand in Java projects:

- switching JDKs when projects require different Java versions
- building and deploying WARs to Tomcat
- building and running Spring Boot applications
- attaching `dape` to Tomcat or Spring Boot debug ports
- jumping between MyBatis mapper interfaces and XML files
- decompiling `.class` files with FernFlower

## Features

- Project-aware root detection using Emacs `project.el`
- Per-process JDK overrides for build/run flows without mutating global `JAVA_HOME`
- Tomcat mode-line status and ready notifications
- Spring Boot mode-line status and ready notifications
- Optional `dape` integration for JPDA attach

## Requirements

- Emacs 29.1+
- macOS or Linux
- Java toolchain installed locally
- Maven and/or Gradle wrappers depending on the project
- Tomcat installed locally if using Tomcat deploy commands
- Optional:
  - `dape`
  - `eglot`
  - `fernflower`

## Installation

Clone the repository and load `java-server.el` from your Emacs configuration.

Example with `use-package`:

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
- `M-x java-server-mapper-find-xml`
- `M-x java-server-decompile-class`

## Notes

- Tomcat deploy currently assumes a Maven WAR build.
- Spring Boot run supports Maven and Gradle builds.
- Project-specific JDK resolution currently reads Maven `pom.xml`.

