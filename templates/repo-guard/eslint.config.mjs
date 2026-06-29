// repo-guard scaffold.
// JS flat-config starter. Needs `eslint`, `@eslint/js`, `eslint-config-prettier`.

import js from "@eslint/js";
import eslintConfigPrettier from "eslint-config-prettier";

const ignores = [
	"node_modules/**",
	"dist/**",
	"build/**",
	"coverage/**",
	".repo-guard/**",
	"*.min.js",
	"*.bundle.js",
	"*.eslintcache",
];

const commonRules = {
	"no-eval": "error",
	"no-implied-eval": "error",
	"no-new-func": "error",
	"no-alert": "error",
	"no-console": ["warn", { allow: ["warn", "error"] }],
	"no-iterator": "error",
	"no-proto": "error",
	"no-script-url": "error",
	eqeqeq: ["error", "smart"],
	curly: "error",
	"no-duplicate-imports": "error",
	"no-self-compare": "error",
	"no-unsafe-finally": "error",
	"prefer-const": "error",
	"no-var": "error",
	"no-unused-vars": [
		"error",
		{ argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
	],
};

export default [
	{ ignores },
	js.configs.recommended,
	{
		files: ["**/*.{js,mjs,jsx}"],
		languageOptions: {
			ecmaVersion: "latest",
			sourceType: "module",
		},
		rules: commonRules,
	},
	{
		files: ["**/*.cjs"],
		languageOptions: {
			ecmaVersion: "latest",
			sourceType: "commonjs",
		},
		rules: commonRules,
	},
	eslintConfigPrettier,
];
