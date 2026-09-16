#!/usr/bin/env sh

#
# Copyright 2015 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Add default JVM options here. You can also use JAVA_OPTS and GRADLE_OPTS to pass any JVM options to Gradle.
DEFAULT_JVM_OPTS=""

APP_NAME="Gradle"
APP_BASE_NAME=`basename "$0"`

# Use the maximum available, or set MAX_FD != -1 to use that value.
MAX_FD="maximum"

warn () {
    echo "$*"
}

die () {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

# OS specific support (must be 'true' or 'false').
cygwin=false
msys=false
darwin=false
nonstop=false
case "`uname`" in
  CYGWIN* )
    cygwin=true
    ;;
  Darwin* )
    darwin=true
    ;;
  MINGW* )
    msys=true
    ;;
  NONSTOP* )
    nonstop=true
    ;;
esac

# Attempt to realpath executable if it's a symlink
if [ -L "$0" ]; then
    # Use readlink to resolve the symlink
    APP_HOME=`readlink "$0"`
else
    APP_HOME=`dirname "$0"`
fi

# For Cygwin, ensure paths are in UNIX format before anything is touched
if $cygwin ; then
    [ -n "$APP_HOME" ] &&
        APP_HOME=`cygpath --unix "$APP_HOME"`
    [ -n "$JAVA_HOME" ] &&
        JAVA_HOME=`cygpath --unix "$JAVA_HOME"`
    [ -n "$CLASSPATH" ] &&
        CLASSPATH=`cygpath --path --unix "$CLASSPATH"`
fi

# Resolve GRADLE_HOME
if [ -z "$GRADLE_HOME" ] ; then
    # In execution dir
    if [ -f "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" ] ; then
        GRADLE_HOME="$APP_HOME"
    else
        # Try relative to execution dir
        if [ -f "../gradle/wrapper/gradle-wrapper.jar" ] ; then
            GRADLE_HOME=".."
        else
            die "Neither \$GRADLE_HOME nor the gradle wrapper has been found."
        fi
    fi
fi
# For Cygwin, switch paths to Windows format before running java
if $cygwin ; then
    GRADLE_HOME=`cygpath --path --windows "$GRADLE_HOME"`
    JAVA_HOME=`cygpath --path --windows "$JAVA_HOME"`
    CLASSPATH=`cygpath --path --windows "$CLASSPATH"`
fi

# Set search paths for commands
if $cygwin ; then
    # We use the sourced .bash_profile for the path
    # based on the assumption that the user has these tools
    # in their path. We need them to run the command.
    . ~/.bash_profile
else
    # We use the normal path
    PATH=$PATH
fi

# Determine the Java command to use to start the JVM.
if [ -n "$JAVA_HOME" ] ; then
    if [ -x "$JAVA_HOME/jre/sh/java" ] ; then
        # IBM's JDK on AIX uses strange locations for the executables
        JAVACMD="$JAVA_HOME/jre/sh/java"
    else
        JAVACMD="$JAVA_HOME/bin/java"
    fi
    if [ ! -x "$JAVACMD" ] ; then
        die "ERROR: JAVA_HOME is set to an invalid directory: $JAVA_HOME

Please set the JAVA_HOME variable in your environment to match the
location of your Java installation."
    fi
else
    JAVACMD="java"
    which java >/dev/null 2>&1 || die "ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH.

Please set the JAVA_HOME variable in your environment to match the
location of your Java installation."
fi

# Increase the maximum file descriptors if we can.
if ! $cygwin && ! $msys && ! $nonstop ; then
    if [ "$MAX_FD" = "maximum" -o "$MAX_FD" = "max" ]; then
        # Use the maximum available file descriptors
        MAX_FD_LIMIT=`ulimit -H -n`
        if [ $? -eq 0 ] ; then
            if [ "$MAX_FD_LIMIT" != "unlimited" ] ; then
                ulimit -n $MAX_FD_LIMIT
            fi
        fi
    fi
fi

# Add the jar to the classpath
if [ ! -f "$GRADLE_HOME/gradle/wrapper/gradle-wrapper.jar" ] ; then
    die "The gradle wrapper has not been found in '$GRADLE_HOME/gradle/wrapper/gradle-wrapper.jar'."
fi
CLASSPATH="$GRADLE_HOME/gradle/wrapper/gradle-wrapper.jar"

# Split up the JVM options only if spaces are available
JVM_OPTS=
if [ -n "$DEFAULT_JVM_OPTS" ]; then
    JVM_OPTS="$DEFAULT_JVM_OPTS"
fi
if [ -n "$JAVA_OPTS" ]; then
    JVM_OPTS="$JVM_OPTS $JAVA_OPTS"
fi
if [ -n "$GRADLE_OPTS" ]; then
    JVM_OPTS="$JVM_OPTS $GRADLE_OPTS"
fi

# Add default Gradle system properties
if [ -z "$JVM_OPTS" ]; then
    JVM_OPTS="-Dorg.gradle.appname=$APP_BASE_NAME"
else
    JVM_OPTS="$JVM_OPTS -Dorg.gradle.appname=$APP_BASE_NAME"
fi

# Execute Gradle
exec "$JAVACMD" $JVM_OPTS -classpath "$CLASSPATH" org.gradle.wrapper.GradleWrapperMain "$@" 