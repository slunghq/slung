use slung::prelude::*;

#[source(builtin = "ws")]
struct LocalExec {
    #[config]
    path: &'static str,

    reading: f64,
    alert: bool,
}

#[rule(
    watch = [LocalExec::reading],
    priority = 10,
)]
fn on_reading(ctx: &RuleContext) -> Result<()> {
    let reading = ctx.get::<f64>(LocalExec::reading)?;
    ctx.set(LocalExec::alert, reading > 10.0)?;
    Ok(())
}

// for the compiler to be happy
fn main() {}
