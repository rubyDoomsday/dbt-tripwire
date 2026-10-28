{ line = $0; sub(/\r$/, "", line) }
in_comment { if (line ~ /-->/) in_comment = 0; next }
line ~ /<!--/ { if (line !~ /-->/) in_comment = 1; next }
match(line, /^#+/) {
    level = RLENGTH
    if (found && level <= start) exit
    if (!found && tolower(line) ~ /^#+[ \t]*upgrade steps/) { found = 1; start = level; next }
}
found { print line }
