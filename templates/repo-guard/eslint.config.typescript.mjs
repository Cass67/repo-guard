// repo-guard scaffold.
// TS flat-config starter. Needs `eslint`, `typescript-eslint`, `typescript`,
// `eslint-config-prettier`.

import js from "@eslint/js";
import tseslint from "typescript-eslint";
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
	"*.tsbuildinfo",
];

const jsRules = {
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

const tsRules = {
	...jsRules,
	"@typescript-eslint/consistent-type-imports": [
		"error",
		{ prefer: "type-imports" },
	],
	"@typescript-eslint/no-explicit-any": "warn",
	"@typescript-eslint/no-floating-promises": "error",
	"@typescript-eslint/no-misused-promises": [
		"error",
		{ checksVoidReturn: false },
	],
	"@typescript-eslint/no-unsafe-assignment": "error",
	"@typescript-eslint/no-unsafe-call": "error",
	"@typescript-eslint/no-unsafe-member-access": "error",
	"@typescript-eslint/no-unsafe-return": "error",
	"@typescript-eslint/restrict-template-expressions": [
		"error",
		{ allowBoolean: true, allowNumber: true, allowNullish: false },
	],
	"@typescript-eslint/strict-boolean-expressions": "error",
	"@typescript-eslint/no-unused-vars": [
		"error",
		{ argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
	],
};

export default [
	{ ignores },
	js.configs.recommended,
	...tseslint.configs.recommendedTypeChecked,
	{
		files: ["**/*.{ts,tsx,mts,cts}"],
		languageOptions: {
			parserOptions: {
				projectService: true,
			},
		},
		rules: tsRules,
	},
	{
		files: ["**/*.{js,mjs,jsx}"],
		languageOptions: {
			ecmaVersion: "latest",
			sourceType: "module",
		},
		rules: jsRules,
	},
	{
		files: ["**/*.cjs"],
		languageOptions: {
			ecmaVersion: "latest",
			sourceType: "commonjs",
		},
		rules: jsRules,
	},
	eslintConfigPrettier,
];
