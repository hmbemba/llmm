# Package

version       = "0.1.1" 
author        = "Harrison Mbemba"
description   = "Context slurper for LLMs - fetch content from local files, repos, and docs"
license       = "MIT"

srcDir        = "."      
discard """
This defines the root directory for your source code.
"""

bin           = @["ctx"]
discard """
This defines the binary executables you want Nimble to build.
"""

# Dependencies

requires "nim >= 2.0.0"

# Build Configuration

discard """
--- Build Configuration ---
nimble build

"""
--define : ssl
--define : release

before build:
  echo "BEFORE BUILD -> Building ctx version ", version

after build:
    echo "AFTER BUILD -> Build completed successfully!"


# Custom Tasks

task test, "Run the test suite":
  echo "Running tests..."


# Nimble Command Descriptions

discard """
Command               | Description                                                                                                                                           |
--------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
nimble install        | Installs all dependencies listed in your .nimble file. If run without arguments in a project folder, it installs that project's dependencies.       |
nimble install -d     | Installs only the dependencies (skips building your project binary). Useful for CI/CD pipelines.                                                      |
nimble build          | Builds your project based on the bin and srcDir directives.                                                                                       |
nimble run            | Builds and runs the binary immediately. Great for quick testing.                                                                                      |
nimble test           | Looks for a tests directory and runs files starting with t.                                                                                       |
nimble tasks          | Lists all the custom tasks you defined in your .nimble file.                                                                                        |
nimble init           | Interactive wizard to create a new .nimble file for a directory.                                                                                    |
nimble develop        | Sets up the project in "development mode," linking it locally so you can import it in other projects without reinstalling every time you change code. |
nimble search <query> | Searches the official Nimble package directory for libraries.                                                                                         |
"""
