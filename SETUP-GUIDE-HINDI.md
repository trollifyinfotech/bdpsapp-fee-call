# Trollify सेटअप गाइड (हिंदी) — Node.js / CLI / Edge Functions की ज़रूरत नहीं

बस 3 चीज़ें चाहिए: Supabase project का **URL**, **anon key**, और website host करने की जगह।

1. **supabase.com** पर free account बनाकर New Project बनाइए (Region: Mumbai)।
2. **Project Settings → API** से *Project URL* और *anon/publishable key* कॉपी कीजिए।
3. `js/supabase-config.js` खोलकर दोनों जगह paste कीजिए, Save कीजिए। (service_role key कभी मत डालिए।)
4. Supabase में **SQL Editor → New query** खोलिए। `supabase/ALL_IN_ONE.sql` file का पूरा content कॉपी करके paste कीजिए और **Run** दबाइए (सिर्फ एक बार)। इससे सारी tables, security और storage बन जाते हैं।
5. **Authentication → Sign In / Providers → Email** में **"Confirm email" को OFF** कीजिए और Save कीजिए। (यह ज़रूरी है।)
6. **पहला Super Admin:** *Authentication → Users → Add user* से अपना email/password बनाइए (**Auto Confirm User** टिक करें)। फिर SQL Editor में चलाइए:
   ```sql
   update public.user_profiles set is_super_admin = true where email = 'आपका_email';
   ```
7. **Website online करें:** पूरा folder https://app.netlify.com/drop पर drag-and-drop कर दीजिए। जो link मिले उसे खोलिए।
8. **इस्तेमाल:** Super Admin से login → school `register.html` से register करे → आप **Approve** दबाएँ → School Owner login करके Academic Session, Fee Structure बनाए, students और teachers जोड़े।

**Reminders:** कोई scheduler नहीं चाहिए; staff जब app खोलता है तब reminders अपने-आप चलते हैं।

**पहले एक test school पर यह क्रम ज़रूर चलाएँ:** register → approve → session → student → fee collect → call log. कोई error आए तो मुझे भेज दीजिए।
