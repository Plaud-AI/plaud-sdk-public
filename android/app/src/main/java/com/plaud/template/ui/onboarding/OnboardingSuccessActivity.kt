package com.plaud.template.ui.onboarding

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.content.Intent
import android.os.Bundle
import android.view.animation.OvershootInterpolator
import androidx.appcompat.app.AppCompatActivity
import com.plaud.template.databinding.ActivityOnboardingSuccessBinding
import com.plaud.template.ui.main.MainActivity

/**
 * Onboarding third page — connection successful
 * Entrance animation: check icon pops in + title/subtitle fade in
 */
class OnboardingSuccessActivity : AppCompatActivity() {

    private lateinit var binding: ActivityOnboardingSuccessBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityOnboardingSuccessBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.exploreButton.setOnClickListener {
            navigateToMain()
        }

        playEntranceAnimations()
    }

    private fun playEntranceAnimations() {
        // Check icon pops in (spring)
        binding.checkIcon.scaleX = 0f
        binding.checkIcon.scaleY = 0f
        val scaleX = ObjectAnimator.ofFloat(binding.checkIcon, "scaleX", 0f, 1f).apply {
            duration = 600
            interpolator = OvershootInterpolator(1.5f)
        }
        val scaleY = ObjectAnimator.ofFloat(binding.checkIcon, "scaleY", 0f, 1f).apply {
            duration = 600
            interpolator = OvershootInterpolator(1.5f)
        }

        // Text fades in only — pure alpha, no slide (mirrors iOS entrance)
        val titleFade = ObjectAnimator.ofFloat(binding.titleLabel, "alpha", 0f, 1f).apply {
            duration = 400
            startDelay = 300
        }
        val subtitleFade = ObjectAnimator.ofFloat(binding.subtitleLabel, "alpha", 0f, 1f).apply {
            duration = 400
            startDelay = 500
        }

        AnimatorSet().apply {
            playTogether(scaleX, scaleY, titleFade, subtitleFade)
            start()
        }
    }

    private fun navigateToMain() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        startActivity(intent)
        finish()
    }
}
