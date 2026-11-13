# A forecast narrative that is honest about being an extrapolation

Same helper shape as `ai-insight-text.md`, pivoted on a `Months Ahead` key so one row
carries every horizon:

```python
{"id": "fh-ar1", "name": "Ar 1",
 "formula": f'SumIf([{F}/Open AR Amt], [{F}/Months Ahead] = 1)', "format": USD}
{"id": "fh-m1",  "name": "Month 1", "format": MON,
 "formula": f'MaxIf([{F}/Month], [{F}/Months Ahead] = 1)'}
{"id": "fh-growth", "name": "Implied Growth", "format": PCT,
 "formula": f'SumIf(...= 1) / If(SumIf(...= 0) = 0, Null, SumIf(...= 0)) - 1'}
```

Note the division: **`Divide()` does not exist** in Sigma (`gotchas.md` #1) and a bare `/`
by zero poisons the row, so guard with `If(denom = 0, Null, denom)`. Seven formulas on one
customer model had silently never returned a value because of this.

The body states the method and its limits in the same breath:

> Open A/R is `{{[Forecast Helper/Ar 0] | $,.0f}}` at the latest month end. Applying the
> trailing 3-month average growth rate of `{{[Forecast Helper/Implied Growth] | +.1%}}`
> per month projects `{{[Forecast Helper/Ar 1] | $,.0f}}` in
> `{{[Forecast Helper/Month 1] | %b %Y}}` …
>
> ⚑ This is a growth extrapolation, not a model. It carries no error term, assumes the
> last three months' rate continues, and reacts to nothing about collections or
> seasonality. Treat the third month as directional only.

Put the caveat in amber (`#8a6410`), prefixed `&#9873;`, so a reader recognises a caveat
without reading it. A visible limitation reads as rigour; a number presented as a
forecast when it is an extrapolation is a landmine in a customer meeting.

`+.1%` and `+,.1f` render the sign, which is what you want for a change.
