# TIR builder: only the qualified-package rule is lifted for the checker's own annotations (D779)

D769 lifted the whole import rule, which also changed how bare names resolve and broke `plugin_tools/plugin_manifest.l` under the gate (`JsonField` resolved to another declaration). The builder now raises a separate `qualifiedRuleLifted` switch read only by the T0020 qualified-type reachability check.
