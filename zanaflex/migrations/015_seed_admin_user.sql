-- =============================================
-- Zanaflex — 015: Seed default admin user
--
-- Creates the bootstrap administrator account:
--   email:    admin@zanaflex.com.br
--   password: @Admin123
--   role:     admin
--   company:  zanaflex
--
-- Idempotent:
--   * If the user does not exist, it is created (email pre-confirmed).
--   * If the user already exists, only its metadata is upgraded to admin
--     (the password is NOT overwritten on re-runs, to avoid clobbering a
--     rotated production password).
--
-- SECURITY NOTE: This default password is meant only for first login.
-- Rotate it immediately from the admin UI after first sign-in.
--
-- Run AFTER 014_match_documents_filter_acl.sql
-- =============================================

-- =======  UP  ========

DO $$
DECLARE
  v_email     TEXT := 'admin@zanaflex.com.br';
  v_password  TEXT := '@Admin123';
  v_user_id   UUID;
  v_meta      JSONB := '{"role":"admin","company_name":"zanaflex","full_name":"Administrador Zanaflex"}'::jsonb;
BEGIN
  SELECT id INTO v_user_id
    FROM auth.users
   WHERE email = v_email
   LIMIT 1;

  IF v_user_id IS NULL THEN
    -- Create a brand-new confirmed user.
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      email_change,
      email_change_token_new,
      recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      crypt(v_password, gen_salt('bf')),
      NOW(),
      jsonb_build_object('provider','email','providers',ARRAY['email']),
      v_meta,
      NOW(),
      NOW(),
      '',
      '',
      '',
      ''
    );

    INSERT INTO auth.identities (
      id,
      user_id,
      provider_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    ) VALUES (
      gen_random_uuid(),
      v_user_id,
      v_user_id::text,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email',
      NOW(),
      NOW(),
      NOW()
    );

    RAISE NOTICE 'Zanaflex bootstrap admin created: %', v_email;
  ELSE
    -- User already exists — just guarantee admin role + metadata.
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || v_meta,
           updated_at         = NOW()
     WHERE id = v_user_id;

    RAISE NOTICE 'Zanaflex bootstrap admin already exists, metadata upgraded: %', v_email;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM auth.identities WHERE user_id IN (SELECT id FROM auth.users WHERE email = 'admin@zanaflex.com.br');
-- DELETE FROM auth.users WHERE email = 'admin@zanaflex.com.br';
-- NOTIFY pgrst, 'reload schema';
