# Bash Scripting: A Practical Syntax Guide

This guide is a reference for writing and reading Bash (`.sh`) scripts. It explains the language in small pieces, then ends with examples that combine those pieces. The examples are deliberately fragments rather than complete script skeletons.

> **Bash is not the same as `sh`.** Features such as `[[ ... ]]`, arrays, `(( ... ))`, process substitution, `mapfile`, and `declare` are Bash-specific. If a script uses them, run it with Bash rather than assuming `/bin/sh` supports them.

## Before you begin: Bash versions matter

Check the interpreter you will actually use:

```bash
bash --version
/usr/bin/env bash --version
```

Some syntax in this guide requires a newer Bash release:

| Bash version | Features from this guide available by that version |
| --- | --- |
| 3.2 | Indexed arrays, `[[ ... ]]`, `=~`, arithmetic, and process substitution |
| 4.0+ | Associative arrays, `mapfile`, `coproc`, `globstar`, `&>>`, `|&`, and `^^`/`,,` case conversion |
| 4.2+ | The `[[ -v variable ]]` existence test |
| 4.3+ | Name references with `declare -n` |
| 4.4+ | `${value@Q}`-style transformations and `mapfile -d` |

The system-provided Bash on many Macs is 3.2, so examples using the later features require a separately installed newer Bash. A script always gets the version selected by its shebang or invocation; your interactive shell version does not change that.

## 1. Running Bash code

### The shebang

The first line can tell the operating system which interpreter to use when the file is executed directly:

```bash
#!/usr/bin/env bash
```

`env` searches `PATH` for Bash. A fixed path is more predictable when the environment is controlled:

```bash
#!/bin/bash
```

The shebang matters when running `./script.sh`. It is ignored when explicitly running `bash script.sh`.

Make a file executable with:

```bash
chmod +x script.sh
./script.sh
```

Other useful ways to invoke Bash:

```bash
bash script.sh             # Run a file in a new Bash process
bash -n script.sh          # Check syntax without executing commands
bash -x script.sh          # Trace commands as they execute
bash -c 'printf "%s\n" "$HOME"'  # Run a command string
```

Sourcing runs a file in the **current** shell, so variable and directory changes remain afterward:

```bash
source settings.sh
. settings.sh              # Equivalent POSIX spelling
```

## 2. Commands, whitespace, and comments

A simple command consists of a command name and zero or more arguments:

```bash
printf '%s\n' "hello world"
```

Spaces and tabs normally separate words. A newline ends a command. A semicolon can separate commands on one line:

```bash
name=Ada; printf 'Hello, %s\n' "$name"
```

A backslash immediately followed by a newline continues the same logical line:

```bash
printf '%s %s\n' \
  "first" \
  "second"
```

Comments begin with `#` when it appears where a new word could begin:

```bash
# Whole-line comment
count=3  # End-of-line comment
printf '%s\n' "# this is data, not a comment"
```

Bash has no dedicated block-comment syntax. A common way to temporarily ignore literal text is a no-op command with a quoted here-document:

```bash
: <<'COMMENT'
Nothing in this block is executed or expanded.
$HOME remains literal here.
COMMENT
```

`:` is a builtin that does nothing successfully.

## 3. Quoting and escaping

Quoting controls how Bash interprets special characters.

### Unquoted text

Unquoted expansions may undergo word splitting and filename expansion. Literal glob characters are also active:

```bash
printf '%s\n' *.txt
```

### Single quotes

Single quotes preserve every character literally. A single quote cannot occur inside single quotes:

```bash
printf '%s\n' '$HOME is not expanded'
printf '%s\n' 'can'"'"'t'            # Adjacent quoted pieces form one word
```

### Double quotes

Double quotes preserve whitespace and glob characters while still allowing parameter expansion, command substitution, and arithmetic expansion:

```bash
name='Grace Hopper'
printf 'Hello, %s\n' "$name"
printf 'Home: %s; files: %s\n' "$HOME" "$(find . -type f | wc -l)"
```

Inside double quotes, backslash only has special meaning before `$`, backtick, `"`, `\`, or a newline.

### Backslash

A backslash quotes the next character when unquoted:

```bash
printf '%s\n' one\ word
printf '%s\n' \$HOME
```

### ANSI-C quoting

`$'...'` understands C-style escapes:

```bash
printf '%s' $'first\nsecond\tcolumn\n'
```

Common escapes include `\n`, `\t`, `\r`, `\\`, `\'`, `\xHH`, and `\uHHHH`.

### Locale-aware quoting

`$"..."` marks a string for locale translation. It is uncommon in ordinary scripts and should not be confused with `$'...'`.

### The default rule

Quote expansions unless you specifically want splitting or globbing:

```bash
rm -- "$file"              # One exact pathname
printf '%s\n' "$value"     # Preserve whitespace and empty values
```

The `--` convention tells many commands that later words are operands, not options.

## 4. Variables and environment variables

Assignments have no spaces around `=`:

```bash
name='Ada Lovelace'
count=5
empty=
```

Read a variable with parameter expansion:

```bash
printf '%s\n' "$name"
printf '%s\n' "${name} wrote notes"
```

Braces remove ambiguity:

```bash
item=book
printf '%s\n' "${item}s"   # books, not the variable $items
```

Shell variables belong to the current shell. Exported variables are copied into child-process environments:

```bash
export APP_MODE=development
export PATH="$HOME/bin:$PATH"
```

An assignment before a command changes that command's environment only:

```bash
LC_ALL=C sort names.txt
DEBUG=1 ./program
```

Remove a variable with `unset`:

```bash
unset name
unset 'scores[2]'
```

### Variable attributes

`declare` creates variables with Bash-specific attributes:

```bash
declare -i total=0          # Integer: assignments are evaluated arithmetically
declare -r constant='fixed' # Read-only
declare -x mode='test'      # Exported
declare -a items            # Indexed array
declare -A lookup           # Associative array
declare -n ref=target       # Name reference to another variable
```

Inside a function, use `local` to avoid changing a caller's variable:

```bash
local result
local -i index=0
```

Useful introspection:

```bash
declare -p name             # Reusable representation of a variable
printf '%q\n' "$name"      # Shell-escaped representation of a value
```

## 5. Shell expansions

Understanding expansions explains most surprising Bash behavior. In broad terms, Bash performs:

1. brace expansion;
2. tilde expansion;
3. parameter, arithmetic, and command substitution (and process substitution);
4. word splitting;
5. filename expansion;
6. quote removal.

The exact rules depend on context. Quoting normally suppresses word splitting and filename expansion.

### Brace expansion

Brace expansion generates text before variables are expanded:

```bash
printf '%s\n' file{1,2,3}.txt
printf '%s\n' {01..05}
printf '%s\n' {a..f..2}    # a, c, e
mkdir -p project/{src,test,docs}
```

Because it happens first, variables do not define brace ranges:

```bash
end=3
printf '%s\n' {1..$end}    # Does not produce 1 2 3
```

### Tilde expansion

At the start of an unquoted word, `~` represents a home directory:

```bash
printf '%s\n' ~            # Current user's home
printf '%s\n' ~otheruser   # Another user's home, if known
```

Prefer `"$HOME/path"` when building a path inside quotes; `"~/path"` does not expand the tilde.

### Parameter expansion

Basic forms:

```bash
$name
${name}
${array[index]}
```

Defaults and required values:

```bash
${value:-fallback}          # Use fallback if unset or empty
${value-fallback}           # Use fallback only if unset
${value:=fallback}          # Assign fallback if unset or empty, then use it
${value=fallback}           # Assign only if unset
${value:?error message}     # Print error and abort if unset or empty
${value?error message}      # Error only if unset
${value:+replacement}       # Use replacement if set and nonempty
${value+replacement}        # Use replacement if set
```

The colon makes “empty” count the same as “unset.”

String length and slicing:

```bash
text='abcdef'
printf '%s\n' "${#text}"       # 6
printf '%s\n' "${text:2:3}"   # cde
printf '%s\n' "${text: -2}"   # ef; space distinguishes it from :-
```

Prefix and suffix removal use glob patterns:

```bash
path='/var/log/app.log'
printf '%s\n' "${path#*/}"     # var/log/app.log: shortest matching prefix
printf '%s\n' "${path##*/}"   # app.log: longest matching prefix
printf '%s\n' "${path%.*}"    # /var/log/app: shortest matching suffix
printf '%s\n' "${path%%/*}"   # Empty here: longest matching suffix
```

Replacement and case conversion:

```bash
value='one two two'
printf '%s\n' "${value/two/2}"   # one 2 two
printf '%s\n' "${value//two/2}"  # one 2 2
printf '%s\n' "${value/#one/1}"  # Replace at beginning
printf '%s\n' "${value/%two/2}"  # Replace at end
printf '%s\n' "${value^^}"       # Uppercase all characters
printf '%s\n' "${value,,}"       # Lowercase all characters
```

Pattern-based case change can use one character (`^` or `,`) or all matching characters (`^^` or `,,`).

Transformations include:

```bash
printf '%s\n' "${value@Q}"     # Quoted for reuse as shell input
printf '%s\n' "${value@A}"     # Assignment/declaration representation
```

Indirect expansion treats a value as another variable's name:

```bash
target='answer'
answer=42
printf '%s\n' "${!target}"     # 42
```

For extensive indirect access, name references (`declare -n`) are usually clearer.

### Command substitution

`$(...)` runs commands in a subshell and substitutes their standard output, removing trailing newlines:

```bash
current_dir=$(pwd)
line_count=$(wc -l < data.txt)
printf '%s\n' "Today is $(date +%F)"
```

The older backtick form works but nests and quotes poorly:

```bash
result=`command`            # Valid, but prefer $(command)
```

Quote command substitutions unless splitting is intentional.

### Arithmetic expansion

Arithmetic expansion substitutes an integer result:

```bash
x=7
printf '%d\n' "$((x * 3 + 1))"
next=$((x + 1))
```

Variable names inside arithmetic expressions do not need `$`. Bash integer arithmetic supports common C operators, including `+ - * / % **`, comparisons, bitwise operators, `&&`, `||`, `?:`, assignments, and pre/post increment. A leading `0` may mean octal; force base 10 with `10#`:

```bash
month='08'
number=$((10#$month))
```

Division is integer division, and dividing by zero is an error.

### Word splitting and `IFS`

After an **unquoted** parameter, command, or arithmetic expansion, Bash splits results using characters in `IFS` (space, tab, and newline by default):

```bash
words='one two three'
printf '<%s>\n' $words      # Three arguments
printf '<%s>\n' "$words"    # One argument
```

Use `read` when intentionally splitting structured text:

```bash
IFS=: read -r user _ uid _ _ home shell < /etc/passwd
```

Avoid changing global `IFS` unnecessarily.

### Filename expansion (globbing)

Unquoted patterns expand to matching pathnames:

```bash
*.txt                       # Any name ending in .txt
file?.log                   # Exactly one character at ?
[abc]*                      # Begins with a, b, or c
[!0-9]*                     # Does not begin with a digit
```

Useful glob-related shell options:

```bash
shopt -s nullglob           # An unmatched glob expands to nothing
shopt -s failglob           # An unmatched glob is an error
shopt -s dotglob            # Globs can match leading-dot names
shopt -s globstar           # ** recursively traverses directories
shopt -s extglob            # Enable extended patterns
```

Extended glob patterns are:

```text
?(pattern-list)             # Zero or one occurrence
*(pattern-list)             # Zero or more
+(pattern-list)             # One or more
@(pattern-list)             # Exactly one
!(pattern-list)             # Anything except the pattern
```

Alternatives inside a pattern list use `|`, such as `@(jpg|png)`.

## 6. Exit status and command chaining

Every command returns an integer status. `0` means success; `1`–`255` mean some kind of failure.

```bash
command
status=$?                   # Status of the most recent command
printf 'status=%d\n' "$status"
```

Prefer testing a command directly instead of inspecting `$?` later:

```bash
if mkdir archive; then
  printf '%s\n' 'directory created'
fi
```

Logical lists use exit statuses:

```bash
compile && printf '%s\n' 'build succeeded'
compile || printf '%s\n' 'build failed' >&2
first && second || fallback
```

`A && B` runs `B` only if `A` succeeds. `A || B` runs `B` only if `A` fails. Do not treat `A && B || C` as a perfect ternary expression: if `B` fails, `C` also runs.

A semicolon or newline runs the next command regardless:

```bash
first; second
```

An ampersand runs the preceding pipeline asynchronously:

```bash
long_job &
job_pid=$!
wait "$job_pid"
```

## 7. Test expressions

### `[[ ... ]]` for Bash conditions

Inside `[[ ... ]]`, words do not undergo ordinary word splitting or filename expansion. This makes it the preferred Bash conditional construct.

String tests:

```bash
[[ -z $text ]]              # Empty string
[[ -n $text ]]              # Nonempty string
[[ $left == "$right" ]]     # Exact equality
[[ $left != "$right" ]]     # Inequality
[[ $left < $right ]]        # Lexicographic order
[[ $name == *.txt ]]        # Pattern match; pattern is deliberately unquoted
```

Quoting the right side of `==` makes it literal:

```bash
[[ $name == "*.txt" ]]      # Matches the literal text *.txt
```

Regular expression matching uses `=~`:

```bash
if [[ $line =~ ^([A-Za-z]+):([0-9]+)$ ]]; then
  label=${BASH_REMATCH[1]}
  number=${BASH_REMATCH[2]}
fi
```

Store complex regular expressions in a variable to simplify quoting:

```bash
pattern='^[[:space:]]*#'
[[ $line =~ $pattern ]]
```

Integer comparisons:

```bash
[[ $a -eq $b ]]             # Equal
[[ $a -ne $b ]]             # Not equal
[[ $a -lt $b ]]             # Less than
[[ $a -le $b ]]             # Less than or equal
[[ $a -gt $b ]]             # Greater than
[[ $a -ge $b ]]             # Greater than or equal
```

File tests:

```bash
[[ -e $path ]]              # Exists
[[ -f $path ]]              # Regular file
[[ -d $path ]]              # Directory
[[ -L $path ]]              # Symbolic link
[[ -r $path ]]              # Readable
[[ -w $path ]]              # Writable
[[ -x $path ]]              # Executable/searchable
[[ -s $path ]]              # Exists and has nonzero size
[[ $a -nt $b ]]             # a is newer than b
[[ $a -ot $b ]]             # a is older than b
[[ $a -ef $b ]]             # Same device and inode
```

Combine tests with `&&`, `||`, `!`, and parentheses:

```bash
[[ -f $path && ( -r $path || $force == yes ) ]]
```

### `[ ... ]` and `test`

`[` is a command, so spaces around its arguments and closing `]` are required:

```bash
if [ -f "$path" ]; then
  printf '%s\n' 'regular file'
fi

test -f "$path"            # Same underlying test
```

Quote expansions inside `[ ... ]`. For portable `sh`, combine commands outside the brackets:

```bash
[ -f "$path" ] && [ -r "$path" ]
```

### `(( ... ))` for arithmetic conditions

Arithmetic evaluation succeeds when its result is nonzero:

```bash
if (( count > 10 && count % 2 == 0 )); then
  printf '%s\n' 'large even count'
fi

((count++))                 # Increment; status is based on the old value
((++count))                 # Increment; status is based on the new value
```

Under `set -e`, standalone arithmetic whose result is zero can unexpectedly terminate a script. Use an assignment such as `count=$((count + 1))` when status is irrelevant.

## 8. Conditional constructs

### `if`, `elif`, and `else`

`if` checks the exit status of a command or command list:

```bash
if [[ -d $path ]]; then
  printf '%s\n' 'directory'
elif [[ -f $path ]]; then
  printf '%s\n' 'regular file'
else
  printf '%s\n' 'something else or missing'
fi
```

The condition can be any command:

```bash
if grep -q 'needle' file.txt; then
  printf '%s\n' 'found it'
fi
```

### `case`

`case` compares a word against glob patterns:

```bash
case $answer in
  y|yes|YES)
    printf '%s\n' 'accepted'
    ;;
  n|no|NO)
    printf '%s\n' 'declined'
    ;;
  *)
    printf 'Unknown answer: %s\n' "$answer" >&2
    ;;
esac
```

Case terminators:

- `;;` stops after the matching branch.
- `;&` continues with the next branch's commands without testing its pattern.
- `;;&` continues testing later patterns.

## 9. Loops

### `for` over words or array elements

```bash
for color in red green blue; do
  printf '%s\n' "$color"
done

for file in ./*.txt; do
  [[ -e $file ]] || continue
  printf '%s\n' "$file"
done

for arg; do                 # Equivalent to: for arg in "$@"
  printf 'argument: %s\n' "$arg"
done
```

Do not parse filenames with `for file in $(find ...)`; command substitution loses boundaries. Use globs, `find ... -exec`, or NUL-delimited input instead.

### C-style arithmetic `for`

```bash
for ((i = 0; i < 5; i++)); do
  printf '%d\n' "$i"
done
```

Any of the three expressions may be omitted.

### `while`

```bash
count=3
while ((count > 0)); do
  printf '%d\n' "$count"
  ((--count))
done
```

Read a file without damaging whitespace or backslashes:

```bash
while IFS= read -r line || [[ -n $line ]]; do
  printf 'line: %s\n' "$line"
done < input.txt
```

The `|| [[ -n $line ]]` portion processes a final line that has no newline terminator.

### `until`

`until` repeats while its condition fails:

```bash
until [[ -e ready.flag ]]; do
  sleep 1
done
```

### Loop control

```bash
continue                    # Skip to the next iteration
continue 2                  # Affect two nested loop levels
break                       # Leave the loop
break 2                     # Leave two nested loop levels
```

## 10. Functions

The recommended function syntax is:

```bash
greet() {
  local name=${1:-world}
  printf 'Hello, %s\n' "$name"
}
```

You may also encounter the Bash-specific `function` keyword:

```bash
function greet {
  printf 'Hello, %s\n' "${1:-world}"
}
```

`function greet()` is accepted by Bash too, but mixing both forms adds nothing. The `name() { ...; }` form is clearer and is also understood by POSIX shells.

Call it like any command:

```bash
greet 'Linus'
```

Functions receive positional parameters of their own. Variables are otherwise global unless declared `local`.

`return` sets the function's exit status; it does **not** return an arbitrary string:

```bash
is_even() {
  (( $1 % 2 == 0 ))
}

if is_even 12; then
  printf '%s\n' 'even'
fi
```

To produce data, write it to standard output and capture it:

```bash
double() {
  printf '%d\n' "$(( $1 * 2 ))"
}

result=$(double 21)
```

Keep diagnostic messages on standard error so they do not contaminate captured output.

## 11. Script and function arguments

Special parameters:

```bash
$0                           # Script or shell name
$1, $2, ...                  # Positional arguments
${10}                        # Braces required for 10 and above
$#                           # Number of positional arguments
"$@"                         # Every argument as a separate word
"$*"                         # All arguments joined into one word by first IFS char
$?                           # Most recent exit status
$$                           # Current shell's process ID
$!                           # PID of most recent background pipeline
$-                           # Current shell option flags
$_                           # Last argument of the previous simple command (context-dependent)
```

Almost always iterate arguments with `"$@"`:

```bash
for argument in "$@"; do
  printf '<%s>\n' "$argument"
done
```

Remove positional arguments with `shift`:

```bash
first=$1
shift
printf 'Remaining count: %d\n' "$#"
```

Replace them with `set --`:

```bash
set -- alpha 'two words' gamma
```

### Parsing short options with `getopts`

`getopts` handles short options without launching another program:

```bash
while getopts ':f:n:v' option; do
  case $option in
    f) file=$OPTARG ;;
    n) count=$OPTARG ;;
    v) verbose=true ;;
    :) printf 'Option -%s needs a value\n' "$OPTARG" >&2 ;;
    \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2 ;;
  esac
done
shift "$((OPTIND - 1))"
```

In `:f:n:v`, a colon after a letter means that option needs an argument. A leading colon enables controlled error handling. Remaining non-option operands are in `"$@"` after the `shift`.

## 12. Indexed arrays

Create and access an indexed array:

```bash
colors=(red 'light green' blue)
colors[3]=yellow
printf '%s\n' "${colors[1]}"
```

Expand elements safely:

```bash
printf '%s\n' "${colors[@]}"  # Each element remains a separate word
printf '%s\n' "${colors[*]}"  # All elements joined into one word
printf '%d\n' "${#colors[@]}" # Number of elements
printf '%s\n' "${!colors[@]}" # Existing indices
```

Slices and appending:

```bash
subset=("${colors[@]:1:2}")
colors+=(purple 'dark orange')
```

Arrays can be sparse, so `${#array[@]}` is not necessarily the next free index. Append with `+=` rather than calculating an index.

Iterate safely:

```bash
for color in "${colors[@]}"; do
  printf '<%s>\n' "$color"
done
```

## 13. Associative arrays

Associative arrays use string keys and must be declared:

```bash
declare -A capitals=(
  [Canada]=Ottawa
  [Japan]=Tokyo
  [France]=Paris
)

capitals[Italy]=Rome
printf '%s\n' "${capitals[Japan]}"
```

Iterate keys and values:

```bash
for country in "${!capitals[@]}"; do
  printf '%s -> %s\n' "$country" "${capitals[$country]}"
done
```

Associative-array iteration order is not guaranteed. Check whether a key exists with:

```bash
if [[ -v 'capitals[Canada]' ]]; then
  printf '%s\n' 'key exists'
fi
```

## 14. Input and output

### `printf`

Prefer `printf` for predictable output:

```bash
printf '%s\n' "$message"
printf 'name=%s count=%d\n' "$name" "$count"
printf -v padded '%05d' 42  # Assign output to a variable
```

Useful format conversions include `%s` (string), `%d` (integer), `%f` (floating-point formatting), `%q` (shell-escaped), and `%b` (interpret backslash escapes in an argument).

Never let untrusted data become the format string:

```bash
printf '%s\n' "$user_text"   # Safe
```

### `echo`

`echo` is convenient for simple fixed strings, but handling of `-n` and backslash escapes varies. Prefer `printf` in reusable scripts.

### `read`

```bash
IFS= read -r line            # Preserve leading/trailing whitespace and backslashes
read -r first rest           # Split across variables using IFS
read -r -p 'Name: ' name     # Prompt (Bash-specific)
read -r -s -p 'Secret: ' secret  # Silent input
read -r -n 1 key             # One character
read -r -t 5 answer          # Five-second timeout
read -r -u 3 line            # Read from file descriptor 3
```

### `mapfile` / `readarray`

Read lines directly into an indexed array:

```bash
mapfile -t lines < input.txt
mapfile -d '' -t files < <(find . -type f -print0)
```

`-t` removes the delimiter; `-d ''` uses NUL as the delimiter. `readarray` is a synonym.

## 15. Redirection and file descriptors

Every process normally begins with three file descriptors:

- `0`: standard input (`stdin`)
- `1`: standard output (`stdout`)
- `2`: standard error (`stderr`)

Basic redirections:

```bash
command > output.txt        # Replace file with stdout
command >> output.txt       # Append stdout
command < input.txt         # Read stdin from file
command 2> errors.txt       # Replace file with stderr
command 2>> errors.txt      # Append stderr
command > all.txt 2>&1      # Send stdout and stderr to the same destination
command &> all.txt          # Bash shorthand for both streams
command &>> all.txt         # Bash shorthand to append both streams
command > /dev/null         # Discard stdout
command 2>&1                # Send stderr wherever stdout currently goes
```

Order matters because redirections are applied left to right:

```bash
command > file 2>&1         # Both streams go to file
command 2>&1 > file         # stderr goes to old stdout; stdout goes to file
```

Other descriptor forms:

```bash
command 3< input.txt        # Open descriptor 3 for reading
command 3> output.txt       # Open descriptor 3 for writing
command 3>> output.txt      # Open descriptor 3 for appending
command 3>&1                # Duplicate stdout onto descriptor 3
command 3<&0                # Duplicate stdin onto descriptor 3
command 3>&-                # Close output descriptor 3
command 3<&-                # Close input descriptor 3
command <> data.txt         # Open the file on stdin for reading and writing
```

`set -C` (also called `set -o noclobber`) prevents `>` from replacing an existing regular file. `>|` overrides that setting for one redirection:

```bash
set -C
command >| deliberately-replaced.txt
set +C
```

Attach a redirection to a whole compound command:

```bash
{
  printf '%s\n' 'first'
  printf '%s\n' 'second'
} > output.txt
```

### Here-documents

A here-document supplies multiple lines of input:

```bash
cat <<EOF
User: $USER
Directory: $PWD
EOF
```

Quote the delimiter to prevent expansion:

```bash
cat <<'EOF'
$USER remains literal.
So does $(date).
EOF
```

`<<-EOF` strips leading **tab characters** from the body and delimiter, which can help indentation.

### Here-strings

A here-string supplies one string plus a trailing newline:

```bash
grep -q 'needle' <<< "$text"
```

### Managing custom descriptors

Let Bash allocate an unused descriptor:

```bash
exec {log_fd}>> application.log
printf '%s\n' 'started' >&"$log_fd"
exec {log_fd}>&-             # Close it
```

`exec` with only redirections changes the current shell's descriptors.

## 16. Pipelines

A pipeline connects each command's stdout to the next command's stdin:

```bash
producer | filter | consumer
```

By default, a pipeline's status is the last command's status. Enable `pipefail` to use the rightmost failing status instead:

```bash
set -o pipefail
generate | transform | save
printf '%s\n' "${PIPESTATUS[@]}"  # Status of every command in last foreground pipeline
```

`|&` pipes both stdout and stderr from the left command:

```bash
command |& logger
```

Pipeline commands normally run in subshell environments, so variable assignments made inside may not survive:

```bash
count=0
printf '%s\n' a b | while read -r _; do
  ((count++))
done
printf '%d\n' "$count"      # Commonly still 0
```

Redirect the loop instead when its state must remain:

```bash
count=0
while read -r _; do
  ((count++))
done < <(printf '%s\n' a b)
```

## 17. Process substitution

Process substitution exposes a command's input or output as a file-like path:

```bash
diff <(sort old.txt) <(sort new.txt)
tee >(gzip > copy.gz) >(sha256sum > copy.sha256) < source.dat > /dev/null
```

- `<(command)` lets another command read `command`'s output.
- `>(command)` lets another command write into `command`'s input.

Unlike command substitution, process substitution does not capture output into a string and therefore does not strip trailing newlines.

## 18. Grouping, subshells, and command scope

Braces run commands in the current shell. Spaces and a terminating semicolon or newline are required:

```bash
{
  value=changed
  printf '%s\n' "$value"
}
printf '%s\n' "$value"      # changed
```

Parentheses run commands in a subshell:

```bash
location=$PWD
(
  cd /tmp || exit
  printf '%s\n' "$PWD"
)
printf '%s\n' "$PWD"        # Original directory
```

Subshells are useful for temporary directory, option, trap, or variable changes.

## 19. Command lookup and execution

Bash can run:

- reserved words such as `if`, `for`, and `case`;
- aliases;
- functions;
- builtins such as `cd`, `printf`, and `read`;
- executable files found through `PATH`.

Inspect command resolution with:

```bash
type -a printf
command -V python
```

Bypass a function or alias and use ordinary command lookup with:

```bash
command printf '%s\n' 'text'
```

Run an external file directly with its path. `exec command ...` replaces the current shell process rather than creating another one:

```bash
exec server --port 8080
```

## 20. Jobs, processes, and signals

Background commands and PIDs:

```bash
worker &
pid=$!

if wait "$pid"; then
  printf '%s\n' 'worker succeeded'
else
  printf '%s\n' 'worker failed' >&2
fi
```

Useful job-control commands in interactive shells include `jobs`, `fg`, and `bg`. Non-interactive scripts normally track PIDs and use `wait`.

Send a signal with `kill`:

```bash
kill -TERM "$pid"
kill -0 "$pid"              # Check whether signaling is possible; sends no signal
```

### Traps

`trap` registers commands for signals or shell events:

```bash
temporary_file=$(mktemp)
trap 'rm -f -- "$temporary_file"' EXIT
```

Common traps include `EXIT`, `ERR`, `DEBUG`, `RETURN`, `INT`, `TERM`, and `HUP`.

```bash
trap 'printf "%s\n" "interrupted" >&2; exit 130' INT
trap - INT                  # Restore default handling
trap '' HUP                 # Ignore a signal
trap -p                     # Display current traps
```

Be careful with quoting: a single-quoted trap action is evaluated when the trap fires, while expansions in a double-quoted action happen when the trap is installed.

## 21. Shell options and error handling

Options controlled by `set` include:

```bash
set -e                       # errexit: exit after certain unhandled failures
set -u                       # nounset: error on many unset-variable expansions
set -o pipefail              # Pipeline fails if any component fails
set -x                       # Trace expanded commands
set -n                       # Parse without executing
set +x                       # Disable tracing
```

The often-used combination is:

```bash
set -Eeuo pipefail
```

It is useful, but not magic:

- `-e` has exceptions in conditions, logical lists, pipelines, and other contexts.
- `-u` requires care with optional variables and empty arrays, especially on older Bash versions.
- `pipefail` changes which pipelines count as failures.
- `-E` makes `ERR` traps inherit into functions, substitutions, and subshells.

Handle expected failures explicitly:

```bash
if ! output=$(possibly_failing_command); then
  printf '%s\n' 'command failed' >&2
fi
```

`shopt` controls Bash-specific behaviors:

```bash
shopt -s nullglob
shopt -u nullglob
shopt -q nullglob && printf '%s\n' 'enabled'
```

Temporarily trace a suspicious region:

```bash
set -x
value=$(transform "$input")
set +x
```

Do not enable tracing around secrets: expanded command arguments are printed.

## 22. Common builtins and keywords

These appear frequently in scripts:

```bash
cd directory                 # Change working directory
pwd                          # Print working directory
pushd directory              # Push directory and change to it
popd                         # Return to pushed directory
printf ...                   # Formatted output
read ...                     # Read fields or a line
mapfile ...                  # Read lines into an array
source file                  # Execute a file in this shell
alias name='command'         # Textual command alias (mainly interactive use)
unalias name                 # Remove alias
declare ...                  # Set variable attributes
local ...                    # Function-local variable
readonly name                # Make a variable immutable
export name                  # Add variable to child environments
unset name                   # Remove variable or function
type command                 # Describe command resolution
help builtin                 # Show Bash help
history                      # Shell history (mainly interactive)
hash                         # Manage remembered command paths
true                         # Successful status
false                        # Failing status
:                             # Successful no-op
return [status]              # Leave function or sourced file
exit [status]                # Leave the shell
break [n]                    # Leave loop(s)
continue [n]                 # Advance loop(s)
wait [pid]                   # Wait for background work
trap action signal           # Install signal/event handler
umask mask                   # Set permissions mask for newly created files
```

Use `help name` for Bash's built-in documentation, for example `help read`, `help [[`, or `help declare`.

## 23. Less-common syntax worth recognizing

### Coprocesses

`coproc` starts an asynchronous process with pipes for two-way communication:

```bash
coproc TRANSFORMER { tr '[:lower:]' '[:upper:]'; }
printf '%s\n' 'hello' >&"${TRANSFORMER[1]}"
exec {TRANSFORMER[1]}>&-
IFS= read -r reply <&"${TRANSFORMER[0]}"
wait "$TRANSFORMER_PID"
```

### `select`

`select` displays a numbered menu and reads a choice:

```bash
select color in red green blue; do
  [[ -n $color ]] || continue
  printf 'Selected %s\n' "$color"
  break
done
```

The raw user input is available in `REPLY`.

### Time a pipeline

The `time` reserved word can time a whole pipeline:

```bash
time generate | compress > archive.gz
```

Customize its Bash output with the `TIMEFORMAT` variable.

### Negating a pipeline

`!` reverses a pipeline's success status:

```bash
if ! grep -q 'enabled' config.ini; then
  printf '%s\n' 'setting is absent'
fi
```

## 24. Safe patterns and common mistakes

### Quote data, not syntax

```bash
[[ $file == *.txt ]]         # Pattern is syntax, so leave it unquoted
rm -- "$file"                # File value is data, so quote it
```

### Preserve arguments with arrays

Do not assemble a command in a string:

```bash
# Fragile: options='--name "two words"'
#          program $options
```

Use an array:

```bash
options=(--name 'two words')
[[ $verbose == true ]] && options+=(--verbose)
program "${options[@]}"
```

### Avoid `eval` for ordinary data

`eval` parses text as shell code, which easily creates quoting bugs and command-injection vulnerabilities. Arrays, associative arrays, `printf -v`, and name references solve most cases without reparsing code.

### Keep filenames intact

Filenames can contain spaces, tabs, newlines, glob characters, and leading hyphens. Quote expansions and prefer NUL-delimited interfaces:

```bash
while IFS= read -r -d '' file; do
  printf '%q\n' "$file"
done < <(find . -type f -print0)
```

### Do not parse `ls`

Use globs or `find` rather than treating display-oriented `ls` output as machine-readable input.

### Check `cd`

```bash
cd "$directory" || exit 1
```

Otherwise later commands may run in the wrong directory.

### Use `mktemp` for temporary paths

```bash
temp_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$temp_dir"' EXIT
```

Only remove a path you created and validated. Never construct a broad removal target from unchecked or possibly empty variables.

### Prefer `$(...)` over backticks

It nests cleanly and makes quoting easier to read.

### Know when glob and regex syntax differ

```bash
[[ $name == *.txt ]]         # Glob
[[ $name =~ \.txt$ ]]        # Extended regular expression
```

`*` means “any string” in a glob but “repeat the previous item” in a regular expression.

### Use ShellCheck

[ShellCheck](https://www.shellcheck.net/) detects many quoting, portability, and data-flow mistakes:

```bash
shellcheck script.sh
```

## 25. Combined examples

These fragments deliberately omit boilerplate. Read them by tracing expansions, conditions, exit statuses, and data flow.

### Example A: Build a command safely

```bash
input='records with spaces.csv'
output='selected.csv'
column=4
verbose=true

awk_options=(-F, -v "column=$column")
[[ $verbose == true ]] && awk_options+=(-v verbose=1)

awk "${awk_options[@]}" '
  NR == 1 || $column != "" {
    if (verbose) printf "keeping line %d\n", NR > "/dev/stderr"
    print
  }
' "$input" > "$output"
```

Things to notice:

- The array preserves each option as one argument.
- `[[ ... ]] && ...` conditionally appends an option.
- The single-quoted AWK program is passed literally to `awk`; its `$column` belongs to AWK, not Bash.
- The quoted Bash pathnames remain single arguments.
- Standard output becomes the result file while AWK diagnostics go to standard error.

### Example B: Classify files and count extensions

```bash
declare -A extension_counts=()

while IFS= read -r -d '' path; do
  name=${path##*/}

  if [[ $name == *.* && $name != .* ]]; then
    extension=${name##*.}
    ((extension_counts[$extension] += 1))
  else
    ((extension_counts['(none)'] += 1))
  fi
done < <(find . -maxdepth 1 -type f -print0)

for extension in "${!extension_counts[@]}"; do
  printf '%-12s %d\n' "$extension" "${extension_counts[$extension]}"
done
```

Things to notice:

- `find -print0` and `read -d ''` preserve every valid filename.
- Process substitution keeps the `while` loop in the current shell, so its array updates survive.
- `${path##*/}` and `${name##*.}` remove the longest matching prefixes.
- The associative array maps each extension to its count.

### Example C: Validate and transform structured input

```bash
record_pattern='^([[:alpha:]_][[:alnum:]_]*):([0-9]+)$'

while IFS= read -r record || [[ -n $record ]]; do
  [[ -z $record || $record == \#* ]] && continue

  if [[ $record =~ $record_pattern ]]; then
    key=${BASH_REMATCH[1]}
    raw_number=${BASH_REMATCH[2]}
    number=$((10#$raw_number))
    printf '%s=%d\n' "${key^^}" "$((number * 2))"
  else
    printf 'invalid record: %q\n' "$record" >&2
  fi
done < records.txt
```

Things to notice:

- Blank lines and lines beginning with `#` are skipped.
- The regular expression captures a key and decimal digits.
- `10#` prevents leading-zero values from being interpreted as octal.
- `${key^^}` uppercases the key; arithmetic expansion doubles the value.
- `%q` prints invalid input in an unambiguous escaped form.

### Example D: Run concurrent work and collect failures

```bash
declare -A task_for_pid=()
pids=()

for task in alpha beta gamma; do
  process_one "$task" > "${task}.out" 2> "${task}.err" &
  pid=$!
  pids+=("$pid")
  task_for_pid[$pid]=$task
done

failed=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then
    printf 'finished: %s\n' "${task_for_pid[$pid]}"
  else
    printf 'failed: %s\n' "${task_for_pid[$pid]}" >&2
    failed=1
  fi
done

((failed == 0))
```

Things to notice:

- `&` starts each function call concurrently and `$!` captures its PID.
- An indexed array retains launch order; an associative array relates each PID to a task.
- `wait` returns the corresponding job's status.
- The last arithmetic condition produces an overall success or failure status.

### Example E: Use a temporary workspace with cleanup

```bash
work_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if curl -fsS "$url" -o "$work_dir/download" \
  && gzip -t "$work_dir/download"; then
  gzip -dc "$work_dir/download" > "$destination"
else
  printf 'download or validation failed\n' >&2
  exit 1
fi
```

Things to notice:

- The temporary directory is created before the cleanup trap is installed.
- The `EXIT` trap runs for normal completion and most explicit exits.
- `&&` prevents validation unless the download succeeds.
- The `if` condition treats failure as expected control flow.
- Quoted paths protect the generated pathname as well as the destination.

### Example F: Compare two generated views without intermediate files

```bash
if diff -u \
  <(cut -d: -f1 /etc/passwd | sort) \
  <(printf '%s\n' "${expected_users[@]}" | sort); then
  printf '%s\n' 'user lists match'
else
  status=$?
  ((status == 1)) \
    && printf '%s\n' 'user lists differ' >&2 \
    || printf 'diff failed with status %d\n' "$status" >&2
fi
```

Things to notice:

- Each `<(...)` becomes a readable file-like input for `diff`.
- `"${expected_users[@]}"` passes every array item separately to `printf`.
- `diff` uses status `1` for “different” and values above `1` for an operational error.
- The multiline logical list distinguishes those meanings.

## 26. Reading unfamiliar Bash

When studying a script, use this order:

1. Identify how it is invoked and which Bash options are enabled.
2. Find inputs: arguments, environment variables, files, and stdin.
3. Mark expansions and decide which are quoted.
4. Track each command's stdout, stderr, redirections, and exit status.
5. Note subshell boundaries: pipelines, `(...)`, command substitutions, and process substitutions.
6. Track mutations to variables, arrays, the working directory, traps, and background jobs.
7. Inspect external commands with their own documentation; Bash only arranges their arguments and streams.

Useful investigation commands:

```bash
bash -n script.sh            # Syntax check
shellcheck script.sh         # Static analysis
bash -x script.sh            # Execution trace
help '[['                    # Bash help for conditional syntax
help read                    # Bash help for the read builtin
type -a command_name         # What Bash will actually run
```

With the syntax above, most Bash scripts become a combination of four ideas: construct exact arguments, route byte streams, branch on exit statuses, and keep track of which shell process owns each piece of state.
