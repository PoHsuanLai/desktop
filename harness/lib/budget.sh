# Step budgets (plan §6.4): a step over twice its budget fails with exit 4.

# budget_exceeded ELAPSED_S BUDGET_S: 0 when ELAPSED_S > 2 * BUDGET_S.
budget_exceeded() { [ "$1" -gt $(( 2 * $2 )) ]; }
