# Contributing

Thank you for looking. Small fixes are welcome, and so are reports from a real machine.

You need: Windows 10 or 11. The tests change nothing on your PC.

1. Fork the repo and make a branch.
2. Change one thing.
3. Run the tests:

   ```
   powershell -ExecutionPolicy Bypass -File tests\run.ps1
   ```

4. Open a pull request. Say what was wrong and how you checked the fix.

## Rules

- Every change must go through `Step`, or the tests fail.
- Undo may only touch the values the block script sets.
- Every claim about Windows needs a link to Microsoft, or a report from a real PC.

New here? Look for issues marked `good first issue`.
