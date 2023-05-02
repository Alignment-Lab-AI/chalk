This directory contains con4m code that Chalk uses for various purposes:

| File | Purpose |
| ---- | ------- |
| chalk.c42spec | This is a specification for what makes a valid chalk file. It is used to validate other files in this directory, and user configuration files, when provided. It contains definitions for the sections and fields allowed, and does extensive input validation. |
| baseconfig.c4m | This is where the default chalk metadata keys are set up, along with other defaults. |
| getopts.c4m | This specifies what is allowed at the command line, validates inputs and provides documentation for all the options.  It's loaded together with baseconfig.c4m (as if #include'd in C). |
| ioconfig.c4m | Sets up defaults for output and reporting. Run after the previous two, so that it can be influenced by command-line arguments. |
| signconfig.c4m | Sets up running external signing tools (currently only GPG). Whether this runs unless --no-load-sign-tools is passed at the command line.  It too is run together with ioconfig.c4m. |
| sbomconfig.c4m | Sets up external sbom collection tools, if --load-sbom-tools is passed.  Also run with ioconfig.c4m |
| sastconfig.c4m | Sets up external static analysis collection tools, if --load-sast-tools is passed, in which case it runs with ioconfig.c4m |
| defaultconfig.c4m | This is a 'default' user config file that runs, if no other user configuration file is embedded in the binary.  It runs after the above, but before any on-filesystem config, if provided. |
| dockercmd.c4m | This config file is used in parsing the *docker* command line, or our container chalking and wrapping. It accepts a superset of valid docker command lines.|
| entrypoint.c4m | This isn't a valid con4m file; it's a template for a valid con4m file.  When wrapping docker entrypoints, this will be used to generate the configuration file we inject into the chalk binary to properly handle entry point execution. |